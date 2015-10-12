{-
   Copyright (c) Microsoft Corporation
   All rights reserved.

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS -Wall -Werror #-}
module CgAtomix where


import AstName
import AstExpr
-- import AstComp
import AstUnlabelled
import Utils
-- import Control.Applicative ( (<$>) )
import Outputable 
-- import Data.Maybe ( fromJust, isJust )
-- import qualified Data.Set as S

import Data.Map.Strict ( Map ) 
import qualified Data.Map.Strict as Map

import qualified Language.C.Syntax as C
import Language.C.Quote.C

-- import Control.Monad.Identity
import Control.Monad ( when )
import Data.Loc
import Data.Maybe
import Text.PrettyPrint.HughesPJ
-- import qualified GenSym as GS
import Data.List ( nub, partition )
-- import CtExpr 
-- import CtComp
-- import TcRename 
import AtomComp

-- import Analysis.DataFlow 
import Opts
import CgMonad
import CgTypes
import CgFun
import CgExpr
-- import CgCmdDom

import AtomixCompTransform 
import AutomataModel
import AtomInstantiation


{- Note [Single Thread Queues]
   ~~~~~~~~~~~~~~~~~~~~~~~~~~
   Which queues are single threaded? This is CPU-dependent. Since queues
   are implemented in shared memory, we only need to make sure that these
   queues cannot have a producer and a consumer operating on them at the
   same time. This implies that a queue is single-threaded iff it is 
   single threaded in /every/ state. Note that core allocation of the 
   corresponding components might be different though. But because states
   synchronize, what matters is the single-threaded-ness within a state. 

   The qi_cores field keeps a map from queue id to a list of
   state-specific readers and writers. If every list in the co-domain is 
   a singleton list then the queue is "single threaded".
--------------------------------------------------------------------------}


cgRnSt :: DynFlags -> AxAuto SymAtom -> RnSt -> Cg a -> Cg a
cgRnSt dfs auto (RnSt { st_bound_vars = bound
                 , st_fundefs    = fdefs
                 , st_structs    = sdefs }) action
  = cg_sdefs sdefs $
    cg_fdefs fdefs $
    cg_bound bound $ action
  where
    cg_sdefs [] m = m
    cg_sdefs ((_,sd):sds) m
      = cg_sdefs sds (cgStructDef sd m)
    cg_fdefs [] m = m
    cg_fdefs ((_,(fun,clos)):fds) m
      | is_external fun
      = cg_fdefs fds (cgFunExternal dfs (funLoc fun) fun m)
      | otherwise
      = cg_fdefs fds (cgFunDefined_clos dfs (funLoc fun) fun clos m)
    cg_bound [] m = m
    cg_bound (x:xs) m
      | x `elem` volatile
      = cg_bound xs (cgGlobMutBindVol dfs noLoc x m)
      | otherwise
      = cg_bound xs (cgGlobMutBind dfs noLoc x m)

    is_external (MkFun (MkFunExternal {}) _ _) = True
    is_external _ = False

    volatile = catMaybes $ 
               map (decision_var . state_decision . node_kind) $
               Map.elems $ 
               auto_graph auto

    decision_var :: Decision Int -> Maybe EId
    decision_var (AtomixBranch v _ _) = Just v
    decision_var _ = Nothing


lblOfNid :: Int -> CLabel
lblOfNid x = "BLOCK_" ++ show x

wiredAtomNameOfLbl :: String -> SrcLoc -> Ty -> EId
wiredAtomNameOfLbl str loc ty = toName (alphaNumStr str) loc ty Imm


mkCastTyArray :: Int -> Ty -> Ty
mkCastTyArray 1 t = t
mkCastTyArray n (TArray (Literal m) t) = TArray (Literal (m*n)) t
mkCastTyArray n t                      = TArray (Literal n) t

-- | Datatype with queue information of this automaton 
data QueueInfo 
  = QI { qi_inch   :: EId                        -- ^ THE Input queue 
       , qi_outch  :: EId                        -- ^ THE Output queue
       , qi_interm :: Map.Map EId (QId,Int)
         -- ^ Intermediate queues, 
         -- ^ their ids and max sizes
         -- ^ as well as a flag indicating
         -- ^ whether it's a local 
         -- ^ queue (i.e. can be just replaced with a variable)
         -- ^ in which case the size must be just one. 
       , qi_cores :: Map.Map EId [[Int]] 
          -- ^ Which cores access each queue, grouped by state, 
          --   See Note [Single Thread Queues]
       , qi_sora_queues :: [(EId,(QId,Int))]  -- SORA concurrent queues
       , qi_sing_queues :: [(EId,(QId,Int))]  -- Ordinary (single-thread) queues
       }

-- | Is this intermediate queue single-threaded? See Note [Single Thread Queues]
isSingleThreadIntermQueue :: QueueInfo -> Chan -> Bool
isSingleThreadIntermQueue qs x = isSingleThreadIntermQueue_aux (qi_cores qs) x

isSingleThreadIntermQueue_aux :: Map.Map EId [[Int]] -> Chan -> Bool
isSingleThreadIntermQueue_aux cores x = 
  case Map.lookup x cores of
    Nothing -> panic $ ppr x <+> text "is not an intermediate queue!"
    Just cs -> all (\state_accessors -> length state_accessors <= 1) cs


instance Outputable QueueInfo where
  ppr (QI qinch qoutch qinterm qcs qsora qsing)
    = vcat [ text "qi_inch   =" <+> text (show qinch)
           , text "qi_outch  =" <+> text (show qoutch)
           , text "qi_interm =" $$ vcat (map ppr_qs (Map.toList qinterm))
           , text "qi_cores  =" $$ vcat (map ppr_cs (Map.toList qcs))
           , text "qi_sora_queues =" $$ vcat (map (text . show) qsora)
           , text "qi_sing_queues =" $$ vcat (map (text . show) qsing)
           ]
    where
-- Obsolete, now qi_sora_queues, and qi_sing_queues have this info
      ppr_cs (qv,qcores) = ppr qv <+> text "used by cores:" <+> 
                                      text (show qcores)
      ppr_qs (qv,(qid,qsz))
         = ppr qv <+> text ":" <+>
           text "qid=" <+> text (show qid) <> text "," <+> 
                                              text "slots=" <+> ppr qsz


newtype QId = QId { unQId :: Int }
  deriving Show
data QueueId = QIn | QOut | QMid QId

qiQueueId :: EId -> QueueInfo -> Maybe QueueId
-- | Return Just the QueueId, if this variable is a queue; Nothing otherwise.
qiQueueId x qs | x == qi_inch qs  = Just QIn
qiQueueId x qs | x == qi_outch qs = Just QOut
qiQueueId x qs | Just (qid,_) <- Map.lookup x (qi_interm qs) = Just (QMid qid)
qiQueueId _ _ = Nothing


cQPtr :: Int -> String
cQPtr n = "q_" ++ show n

-- | Declare queues 
cgDeclQueues :: forall a. DynFlags -> QueueInfo -> Cg a -> Cg a
cgDeclQueues dfs qs action 
  = do cgIO $ print (ppr qs)
       cgGlobMutBind dfs noLoc (qi_inch qs) $
        cgGlobMutBind dfs noLoc (qi_outch qs) $ decl_rest
  where
    -- numqs = Map.size (qi_interm qs)
    num_sora_qs = length $ qi_sora_queues qs
    num_sing_qs = length $ qi_sing_queues qs

    bind_queue_vars qtype qarr queues idxs m = go queues idxs
       where 
         go :: [(EId,(QId,Int))] -> [Int] -> Cg a 
         go [] _ = m 
         go ((_,(QId x,_)):qss) (n:ns) = 
           do let qid = cQPtr x
              appendTopDecl [cdecl| static $ty:qtype * $id:qid;|]
              addGlobalWplAllocated [cstm| $id:qid = & $id:qarr[$int:n];|]
              go qss ns
         go _ _ = error "Can't happen!"

    bind_sora_queue_vars 
      = bind_queue_vars (namedCType "ts_context") "sora_queue_arr"
    bind_sing_queue_vars 
      = bind_queue_vars (namedCType "queue") "sing_queue_arr"

    -- Declare SORA stuff
    my_sizes_decl_sora   = [cdecl|typename size_t my_sizes_sora[$int:(num_sora_qs)];|]
    my_slots_decl_sora   = [cdecl|int my_slots_sora[$int:(num_sora_qs)];|]
    my_batches_decl_sora = [cdecl|int my_batches_sora[$int:(num_sora_qs)];|] 

    -- Declare STQ stuff
    my_sizes_decl_sing   = [cdecl|typename size_t my_sizes_sing[$int:(num_sing_qs)];|]
    my_slots_decl_sing   = [cdecl|int my_slots_sing[$int:(num_sing_qs)];|]

    -- Initialize queue statements
    q_init_stmts_sora 
     = [cstm| sora_queue_arr = s_ts_init_batch($int:(num_sora_qs),
                                                my_sizes_sora,
                                                my_slots_sora,
                                                my_batches_sora); |]
    q_init_stmts_sing    
     = [cstm| sing_queue_arr = stq_init($int:(num_sing_qs),
                                                my_sizes_sing,
                                                my_slots_sing);|]

    my_sizes_inits_sora = concat $ zipWith sizes_inits_sora (qi_sora_queues qs) [0..]
    sizes_inits_sora (qvar,(_,siz)) (i::Int) =
         [ [cstm|
            my_sizes_sora[$int:i] = 
                  $(tySizeOf_C (nameTyp qvar));|]
         , [cstm| my_slots_sora[$int:i] = $int:siz;|] 
         , [cstm| my_batches_sora[$int:i] = 1;|]
         ]

    my_sizes_inits_sing = concat $ zipWith sizes_inits_sing (qi_sing_queues qs) [0..]
    sizes_inits_sing (qvar,(_,siz)) (i::Int) =
         [ [cstm|
            my_sizes_sing[$int:i] =
                  $(tySizeOf_C (nameTyp qvar));|]
         , [cstm| my_slots_sing[$int:i] = $int:siz;|]
         ]

    decl_rest = do 
      -- Declare single thread queues stuff
      when (num_sing_qs > 0) $ do 
         appendTopDecl [cdecl| $ty:(namedCType "queue")* sing_queue_arr;|]
         appendTopDecl my_sizes_decl_sing
         appendTopDecl my_slots_decl_sing
         mapM_ addGlobalWplAllocated (my_sizes_inits_sing ++ [q_init_stmts_sing])
         return ()
 
      -- Declare sora queues stuff
      when (num_sora_qs > 0) $ do
         appendTopDecl [cdecl| $ty:(namedCType "ts_context")* sora_queue_arr;|]
         appendTopDecl my_sizes_decl_sora
         appendTopDecl my_slots_decl_sora
         appendTopDecl my_batches_decl_sora
         mapM_ addGlobalWplAllocated (my_sizes_inits_sora ++ [q_init_stmts_sora])

      bind_sora_queue_vars (qi_sora_queues qs) [0..] $
        bind_sing_queue_vars (qi_sing_queues qs) [0..] action


--     in if numqs == 0 then do 
--          cgGlobMutBind dfs noLoc (qi_inch qs) $ 
--            cgGlobMutBind dfs noLoc (qi_outch qs) $ action 
--         else do 
--           let my_sizes_decl   = [cdecl|typename size_t my_sizes[$int:(numqs)];|]
--               my_slots_decl   = [cdecl|int my_slots[$int:(numqs)];|]
--               my_batches_decl = [cdecl|int my_batches[$int:(numqs)];|] 
--               q_init_stmts 
-- -- Single thread 
--                   = [cstm| queue_arr = stq_init($int:(numqs),my_sizes,my_slots); |]
-- -- Sora threads
-- --                = [cstm| ts_init_batch($int:(numqs),my_sizes, my_slots, my_batches);|]

--               my_sizes_inits 
--                 = concat $
--                   Map.elems $ 
--                   Map.mapWithKey (\qvar (QId i,siz) -- ignore slots
--                          -> let orig = "qvar type = " ++ show (nameTyp qvar)
--                             in [ [cstm| ORIGIN($string:orig);|]
--                                , [cstm|
--                                   my_sizes[$int:i] = 
--                                         $(tySizeOf_C (nameTyp qvar));|]
--                                , [cstm| my_slots[$int:i] = $int:siz;|]
-- {- SORA
--                                , [cstm|
--                                   my_sizes[$int:i] = 
--                                         $(tySizeOf_C (nameTyp qvar));|]
--                                , [cstm| my_slots[$int:i] = 16;|] 
--                                , [cstm| my_batches[$int:i] = $int:siz;|]
-- -}
--                                ]) (qi_interm qs)

--              -- Append top declarations  
--           appendTopDecl [cdecl| $ty:(namedCType "queue")* queue_arr;|]
--           appendTopDecl my_sizes_decl
--           appendTopDecl my_slots_decl
--           appendTopDecl my_batches_decl

--              -- Add code to initialize queues in wpl global init
--           _ <- mapM addGlobalWplAllocated (my_sizes_inits ++ [q_init_stmts])

--           cgGlobMutBind dfs noLoc (qi_inch qs) $ 
--            cgGlobMutBind dfs noLoc (qi_outch qs) $ 
--              bind_queue_vars action
--                 (Map.toList $ qi_interm qs) [0..] -- /Not/ declaring temporaries for queues!
--   where
--     bind_queue_vars m [] _ = m
--     bind_queue_vars m (_q1:qss) (n:ns)
--       = do -- cgIO $ putStrLn ("Declaring temp variable for queue: " ++ show q1)
--            let qid = cQPtr n
--            appendTopDecl [cdecl| static $ty:(namedCType "queue")* $id:qid;|]
--            addGlobalWplAllocated [cstm| $id:qid = & queue_arr[$int:n];|]
--            bind_queue_vars m qss ns
--     bind_queue_vars _ _ _ = error "Can't happen!"


-- | Extract all introduced queues, and for each calculate the maximum
-- ^ size we should allocate it with.
extractQueues :: AxAuto SymAtom -> QueueInfo
extractQueues auto 
  = QI { qi_inch   = auto_inchan auto
       , qi_outch  = auto_outchan auto
       , qi_interm = interms
       , qi_cores  = cores
       , qi_sora_queues = sora_queues
       , qi_sing_queues = sing_queues
       }
  where

    -- All intermediate queues 
    all_interm_queues = Map.toList interms
 
    (sing_queues, sora_queues) 
      = partition (isSingleThreadIntermQueue_aux cores . fst) all_interm_queues

    interms = Map.fromList $ 
               zipWith (\(k,siz) n -> (k,(QId n,siz))) 
                       (Map.toList (unions_with max pre)) [0..]

    -- Sigh .. horribly inefficient
    cores :: Map Chan [[Int]]
    cores = foldl (\x m -> 
                      Map.unionWith (++) x (Map.map (\w -> [w]) m)) 
                  Map.empty pre_cores

    unions_with f = foldl (Map.unionWith f) Map.empty

    pre = map (extract_queue . node_kind) (Map.elems (auto_graph auto))
    extract_queue (AtomixState atoms _ _ init_pipes) 
       = update_pipes atoms init_pipes

    pre_cores :: [Map.Map Chan [Int]]
    pre_cores = map (extract_core . node_kind) (Map.elems (auto_graph auto))
    extract_core (AtomixState atoms _ _ init_pipes)
       = update_cores atoms (Map.map (\_ -> []) init_pipes)

    update_pipes :: [WiredAtom SymAtom] -> Map Chan Int -> Map Chan Int
    update_pipes watoms pipes 
      = Map.map snd $ foldl upd (Map.map (\r -> (r,r)) pipes) watoms
      where upd ps wa = 
               Map.mapWithKey (\q (cur,m) -> 
                   let cur' = cur + countWrites q wa - countReads q wa
                       m'   = max m cur'
                   in (cur',m')) ps

    -- | Add cores that access each queue to the map
    update_cores :: [WiredAtom SymAtom] -> Map Chan [Int] -> Map Chan [Int]
    update_cores watoms pipes = foldl upd_cores pipes watoms
      where upd_cores ps wa = 
               Map.mapWithKey (\q cs -> 
                   if (countWrites q wa > 0 || countReads q wa > 0) 
                   then nub (getWiredAtomCore wa : cs) else cs) ps 


cgAutomatonDeclareAllGlobals :: DynFlags 
            -> RnSt                 -- ^ Records all variables (but no queues)
            -> QueueInfo            -- ^ Queues
            -> AxAuto SymAtom       -- ^ The automaton
            -> Cg ()
            -> Cg ()
cgAutomatonDeclareAllGlobals dfs 
                             st 
                             queues
                             auto@(Automaton { auto_graph   = graph
                                             , auto_start   = _ }) 
                             mo
 = cgRnSt dfs auto st $ 
   cgDeclQueues dfs queues $ 
   cg_define_atoms mo

  where 

   cg_define_atoms       = cg_def_atoms (Map.elems graph)
   cg_def_atoms [] m     = m
   cg_def_atoms (n:ns) m = cg_def_node n (cg_def_atoms ns m)
   cg_def_node (Node _nid nk)    = cg_def_nkind nk
   cg_def_nkind (AtomixState atoms _ _ _) m = cg_def_atoms' atoms m 

   cg_def_atoms' [] m = m
   cg_def_atoms' (a:as) m = cgDefAtom dfs queues a (cg_def_atoms' as m)




-- | Main driver for code generation
cgAutomaton :: DynFlags 
            -> Int                  -- ^ ThreadID
            -> QueueInfo            -- ^ Queues
            -> AxAuto SymAtom       -- ^ The automaton
            -> Cg CLabel            -- ^ Label of starting state we jump to
cgAutomaton dfs atid queues Automaton { auto_graph   = graph
                                      , auto_start   = start }
  = do { cg_automaton atid
       ; return (lblOfNid start) }


  where 
   cg_automaton :: Int -> Cg ()
   cg_automaton c 
     = do { frameVar <- freshVar "mem_idx"
          ; appendDecl [cdecl| unsigned int $id:frameVar; |]
          ; mapM_ (cg_node c frameVar) (Map.elems graph)
          }

   cg_node c frameVar (Node nid nk) = 
     do { if c == 0 then do { cg_declare_barr nid 
                            ; cg_declare_barr2 nid 
                            }
                    else return()
        ; appendLabeledBlockNoScope (lblOfNid nid) (cg_nkind c nid frameVar nk)
        }

   cg_nkind c nid frameVar (AtomixState atoms _ decision _) = do
     inAllocFrame' frameVar noLoc $ pushAllocFrame $ mapM_ (cgCallAtom dfs c queues) atoms
     cg_decision c nid decision

   cg_decision c nid AtomixDone
     = if no_threads == 1 then
           appendStmt [cstm| return 0; |]
         else
           appendStmts [cstms| barrier($id:(barr_name nid), $int:no_threads, $int:c);
                               return 0; |]

   cg_decision c nid (AtomixLoop next)
     = if no_threads == 1 then
           appendStmt [cstm| goto $id:(lblOfNid next); |]
         else
           appendStmts [cstms| //printf("Thread %d in state %d, going to %d\n", $int:c, $int:nid, $int:next);
                               barrier($id:(barr_name nid), $int:no_threads, $int:c); 
                               goto $id:(lblOfNid next); |]

   cg_decision c nid (AtomixBranch c' l r) = do
     cc <- lookupVarEnv c'
     if no_threads == 1 then
         appendStmt [cstm| if ($cc) {
                             goto $id:(lblOfNid l); 
                           } else {
                             goto $id:(lblOfNid r); 
                           }
                         |]
       else
         appendStmts [cstms| //printf("Thread %d in state %d, goind to %d\n", $int:c, $int:nid, $cc);
                             barrier($id:(barr_name nid), $int:no_threads, $int:c);
                             if ($cc) {
                                  barrier($id:(barr_name2 nid), $int:no_threads, $int:c);
                                  //printf("Thread %d in state %d, goind to %d\n", $int:c, $int:nid, $l);
                                  goto $id:(lblOfNid l); 
                             } else {
                                  barrier($id:(barr_name2 nid), $int:no_threads, $int:c);
                                  //printf("Thread %d in state %d, goind to %d\n", $int:c, $int:nid, $r);
                                  goto $id:(lblOfNid r); 
                             }
                           |]

   -- One barrier is before branching decision and the other after
   -- It can happen (and has happened) that one thread moves forward and changes the branching
   -- decision before the other thread reads the old value
   cg_declare_barr  label 
      = appendTopDecl [cdecl| $ty:(namedCType "LONG volatile") $id:(barr_name label)[3] = {0, 0, 0};|];
   cg_declare_barr2 label 
      = appendTopDecl [cdecl| $ty:(namedCType "LONG volatile") $id:(barr_name2 label)[3] = {0, 0, 0};|];

   barr_name label = "__barr_" ++ lblOfNid label
   barr_name2 label = "__barr2_" ++ lblOfNid label
   
   no_threads      = getNoAtomThreads dfs




{---------------------- Defining and calling an atom -------------------------}

cgDefAtom :: DynFlags
          -> QueueInfo
          -> WiredAtom SymAtom
          -> Cg a
          -> Cg a
cgDefAtom dfs qs w@(WiredAtom win wout the_atom)
  = case atom_kind the_atom of
      SACast _ inty outty ->
        let inwire  = head win
            outwire = head wout
        in cg_def_atom dfs wid $ cgACastBody dfs qs inwire outwire inty outty

      SADiscard _ inty 
        -> cg_def_atom dfs wid $ cgADiscBody dfs qs (head win) inty

      SAExp aexp 
        -> cg_def_atom dfs wid $ cgAExpBody dfs qs win wout aexp

      SARollback qvar n 
        -> cg_def_atom dfs wid $ cgARollbackBody dfs qs qvar n

      SAClear qsns      
        -> cg_def_atom dfs wid $ cgAClearBody dfs qs qsns

      SAAssert b 
        -> cg_def_atom dfs wid $ cgAAssertBody dfs qs (head win) b

  where wid = wiredAtomId w

cg_def_atom :: DynFlags 
            -> String   -- atom identifier
            -> Cg C.Exp -- Body 
            -> Cg a     -- Continuation
            -> Cg a
cg_def_atom _dfs aid mbody mkont
  = do mb <- lookupExpFunEnv_maybe fun_name
       case mb of { Just {} -> mkont; Nothing -> cg_define_atom }
  where
    fun_name = wiredAtomNameOfLbl aid noLoc (TArrow [] TUnit)
    cg_define_atom = do 
      (cdecls,cstmts,cbody) <- inNewBlock (pushAllocFrame mbody)

      -- Prototype
      appendTopDecl [cdecl| $ty:(codeGenTyOcc_ (Just "FINL") TUnit) $id:(name fun_name)();|]

      -- Implementation 
      appendTopDef $
        [cedecl| $ty:(codeGenTyOcc_ (Just "FINL") TUnit)
              $id:(name fun_name)() {
                      $decls:cdecls    // Define things needed for body
                      $stms:cstmts     // Emit rest of body
                      return $(cbody);                          
             } |]

      -- Extend environment and go on
      extendExpFunEnv fun_name (fun_name, [], False) mkont


cgCallAtom :: DynFlags
           -> Int
           -> QueueInfo
           -> WiredAtom SymAtom 
           -> Cg ()
cgCallAtom _dfs current_core queues wa 
  | rd_input
  , core == current_core
  = appendStmt $ [cstm| if ($id:(name fun_name)() == -7) return(0);|]

  | core == current_core 
  = appendStmt $ [cstm| $id:(name fun_name)();|]

  | otherwise
  = appendStmt $ [cstm| UNIT;|]

  where
    fun_name = wiredAtomNameOfLbl aid noLoc (TArrow [] TUnit)
    rd_input = rdFromInput queues (wires_in wa)
    aid      = wiredAtomId wa
    core     = getWiredAtomCore wa 

-- | Get the core of a *wired* atom
getWiredAtomCore :: WiredAtom SymAtom -> Int
getWiredAtomCore = fromMaybe 0 . atom_core . the_atom


{---------------------------- Assert atom implementation ----------------------}


-- NB: In the future we can define this one too. 
cgAAssertBody :: DynFlags
              -> QueueInfo
              -> (Int,EId)
              -> Bool
              -> Cg C.Exp
cgAAssertBody dfs qs (_,inwire) b = do 
  let loc = nameLoc inwire
  cgInWiring dfs qs [(1,inwire)] [inwire] $ do 
     let err   = eError loc TUnit "Atomix dead code assertion violation!"
         vunit = eVal loc TUnit VUnit
     _ <- codeGenExp dfs $ 
          if b then eIf loc (eUnOp loc Not (eVar loc inwire)) err vunit
               else eIf loc (eVar loc inwire) err vunit
     return [cexp|UNIT|]

{---------------------------- Rollback atom implementation --------------------}

cgARollbackBody :: DynFlags
                -> QueueInfo
                -> EId
                -> Int
                -> Cg C.Exp
cgARollbackBody _dfs qs q n
  | Just (QMid (QId qid)) <- qiQueueId q qs = do
      appendStmt [cstm| _stq_rollback($int:n,$id:(cQPtr qid)); |]
      return [cexp|UNIT|]
  | otherwise 
  = panic $ vcat [ text "SARollback only implemented for middle queues"
                 , nest 2 $ text "queue = " <+> ppr q
                 , nest 2 $ text "n     = " <+> ppr n 
                 ]

{---------------------- Discard/Clear atom implementation ---------------------}

cgADiscBody :: DynFlags
            -> QueueInfo
            -> (Int,EId) -- ^ inwire
            -> (Int,Ty)  -- ^ inty
            -> Cg C.Exp
cgADiscBody dfs qs (n,inwire) (n',_inty)
  = assert "cgDiscAtom" (n == n') $ 
    cgInWiring dfs qs [(n,inwire)] [inwire] $ return [cexp|UNIT|]

cgAClearBody :: DynFlags 
             -> QueueInfo
             -> Map EId Int
             -> Cg C.Exp
cgAClearBody _dfs qs qmap = do 
  -- For now implement clear via discard
  mapM_ mk_clear $ map (flip qiQueueId qs . fst) $ Map.toList qmap
  return [cexp|UNIT|]
  where
    mk_clear (Just (QMid (QId qid))) = appendStmt [cstm| _stq_clear($id:(cQPtr qid)); |]
    mk_clear _ = panicStr "cgAClearBody: can only clear middle queues"

{--------------------------- AExp atom implementation -------------------------}

cgAExpBody :: DynFlags 
           -> QueueInfo
           -> [(Int,EId)] -- ^ in wires
           -> [(Int,EId)] -- ^ out wires
           -> AExp ()
           -> Cg C.Exp
cgAExpBody dfs qs wins wouts aexp
  = do { when (isDynFlagSet dfs Verbose) dbg_m 
       ; cgInWiring dfs qs wins wires_in $ 
         cgOutWiring dfs qs wouts wires_out $
         codeGenExp dfs fun_body }
  where 
    dbg_m = cgIO $ print $ vcat [ text "cgAExpAtom:" <+> ppr fun_name
                                , text "ivs       :" <+> ppr wires_in
                                , text "ovs       :" <+> ppr wires_out
                                , text "fun_ty    :" <+> ppr (nameTyp fun_name)
                                , text "body was  :" <+> ppr (aexp_exp aexp)
                                ]
    loc  = expLoc (aexp_exp aexp)
    -- input wires
    wires_in  = map snd wins
    -- output wires
    wires_out = map snd wouts
    fun_name  = wiredAtomNameOfLbl (aexp_lbl aexp) loc (TArrow [] TUnit)
    fun_body  = aexp_exp aexp   


{------------------------------- Cast atom implementation ---------------------}

cgACastBody :: DynFlags 
            -> QueueInfo
            -> (Int,EId) -- ^ inwire
            -> (Int,EId) -- ^ outwire
            -> (Int,Ty)  -- ^ inty
            -> (Int,Ty)  -- ^ outty
            -> Cg C.Exp
cgACastBody dfs qs (n,inwire) 
                      (m,outwire) 
                      (n',_inty) 
                      (m',_outty) 
  = assert "cgCastAtom" (n == n' && m == m') $ do
    case (qiQueueId inwire qs, qiQueueId outwire qs) of 

      -- Naked take and emit cases

      (Nothing, _)
        -> assert "cgCastAtom" (n == 1) $
           cgOutWiring dfs qs [(m,outwire)] [outwire] $
           codeGenExp dfs $ eAssign noLoc inwire_exp outwire_exp
      (_,Nothing)  
        -> assert "cgCastAtom" (m == 1) $
           cgInWiring dfs qs [(n,inwire)] [inwire] $
           codeGenExp dfs $ eAssign noLoc inwire_exp outwire_exp

      -- Mitigator case (inefficient for now but oh well ...)

      _ -> cgInWiring dfs qs [(n,inwire) ] [inwire]   $
           cgOutWiring dfs qs [(m,outwire)] [outwire] $ do
              _inptr <- lookupVarEnv inwire
              _outptr <- lookupVarEnv outwire
              appendStmt [cstm| ORIGIN("NOT CORRECT AT ALL!");|]
              appendStmt [cstm| memcpy(& $_outptr, & $_inptr, $int:m * $exp:_tsiz);|]
              return [cexp|UNIT|]

  where inwire_exp  = eVar noLoc inwire
        outwire_exp = eVar noLoc outwire
        _tsiz       = tySizeOf_C (nameTyp outwire)


-- let storage_in_ty  = mkCastTyArray n inty 
--            in do storage <- CgMonad.freshName "cast_storage" storage_in_ty Mut
--                  cgMutBind dfs noLoc storage Nothing $ do 

{- Wiring and infrastructure
 - ~~~~~~~~~~~~~~~~~~~~~~~~~
 -
 - ----------------------------------------------------------------------------}


{--------------- Reading from TS queues ---------------------------------------}

-- q_read_n :: QId -> Int -> C.Exp -> C.Stm
-- q_read_n (QId qid) n ptr
--   = [cstm| ts_getManyBlocking($int:qid,$int:n,$ptr); |]

-- q_read_n_bits :: QId -> Int -> C.Exp -> C.Stm
-- q_read_n_bits (QId qid) n ptr
--   = [cstm| ts_getManyBitsBlocking($int:qid,$int:n,$ptr); |]


-- readFromTs :: DynFlags 
--            -> Int -> Ty -- # number of reads, and type of each read
--            -> QId       -- Queue id
--            -> C.Exp     -- Target variable to store to
--            -> Cg ()
-- readFromTs _ n TBit q ptr = appendStmt $ q_read_n_bits q n ptr

-- readFromTs dfs n (TArray (Literal m) TBit) q@(QId qid) ptr
--   | m `mod` 8 == 0 = appendStmt $ q_read_n q n ptr
--   | n == 1         = appendStmt $ q_read_n q 1 ptr
--   | otherwise -- Not byte-aligned byte array, a bit sad and slow
--   = do x <- CgMonad.freshName "q_rdx" (TArray (Literal m) TBit) Mut
--        i <- CgMonad.freshName "q_idx" tint Mut
--        cgMutBind dfs noLoc i Nothing $ do 
--        cgMutBind dfs noLoc x Nothing $ do
--          cx <- lookupVarEnv x
--          ci <- lookupVarEnv i
--          appendStmt $ [cstm| for ($ci = 0; $ci < $int:n; $ci++) {
--                                 ts_getManyBlocking($int:qid, 1, (char *) $cx);
--                                 bitArrWrite((typename BitArrPtr) $cx,
--                                               $ci*$int:m,
--                                               $int:m,
--                                             (typename BitArrPtr) $ptr);
--                              } |]
-- readFromTs _ n _ q ptr = appendStmt $ q_read_n q n ptr


-- | Do we read from /the/ input
rdFromInput :: QueueInfo -> [(Int,EId)] -> Bool
rdFromInput qs qvars = any rd_in qvars
  where rd_in (_,qvar) | Just QIn <- qiQueueId qvar qs 
                       = True
                       | otherwise                  
                       = False

          
cgInWiring :: DynFlags 
           -> QueueInfo 
           -> [(Int,EId)] -- Input wires
           -> [EId]       -- Where to store things
           -> Cg a 
           -> Cg a
cgInWiring dfs qs ws vs action = go ws vs
  where 
    go [] [] = action
    go (wir:wirs) (tgt:tgts) = cgInWire dfs qs wir tgt (go wirs tgts)
    go _ _ = error "cgInWiring!"

cgDeclQPtr :: EId                       -- | Queue variable (and type of each element)
           -> (C.Exp -> C.Type -> Cg a) -- ^ Action having passed in pointer variable and type
           -> Cg a
cgDeclQPtr q action
  = do q_c <- CgMonad.freshName "_ptr" qty Mut
       let ctype = codeGenSmallTyPtr qty
           cptr  = [cexp|$id:(name q_c)|]
           cval | TArray {} <- qty = cptr
                | otherwise        = [cexp| * $cptr|]
       appendDecl [cdecl| $ty:ctype $id:(name q_c);|]
       extendVarEnv [(q,cval)] $ action cptr ctype
  where qty = nameTyp q

cgInWire :: DynFlags 
         -> QueueInfo  
         -> (Int,EId) -- ^ Queue 
         -> EId       -- ^ Storage 
         -> Cg a      -- ^ Continuation
         -> Cg a     
cgInWire _dfs qs (n,qvar) v action =
  case qiQueueId qvar qs of

    -- Not a queue
    Nothing 
       -> assert "cgInWire/non-queue" (n == 1) $
          assert "cgInWire/not-same-var" (qvar == v) $ action

    Just (QMid (QId qid))
       | isSingleThreadIntermQueue qs qvar
       -> cgDeclQPtr v $ \ptr ptr_ty             
            -> do appendStmt [cstm| $ptr = ($ty:ptr_ty) _stq_acquire($id:(cQPtr qid),$int:n);|]
                  a <- action
                  appendStmt [cstm| _stq_release($id:(cQPtr qid),$int:n);|]
                  return a
       | otherwise
       -> cgDeclQPtr v $ \ptr ptr_ty 
            -> do appendStmt [cstm| $ptr = ($ty:ptr_ty) s_ts_acquire($id:(cQPtr qid),$int:n);|]
                  a <- action
                  appendStmt [cstm| s_ts_release($id:(cQPtr qid),$int:n);|]
                  return a

    -- Unexpected output queue
    Just QOut -> panicStr "cg_in_wire: encountered output queue!"

    -- TODO: the main input queue
    Just QIn -> do
      let qtype = squashedQueueType n (nameTyp qvar)
      
      let (bufget_suffix, getLen) = getTyPutGetInfo qtype
      let bufGetF = "buf_get" ++ bufget_suffix

      buf_context  <- getBufContext
      global_params <- getGlobalParams

      cv <- lookupVarEnv v
      let ptr = if isPtrType (nameTyp v) then [cexp| $cv|] else [cexp| & $cv|]
      if isArrayTy qtype 
        then appendStmt [cstm| if ($id:(bufGetF)($id:global_params,
                                   $id:buf_context,
                                   $ptr, $(getLen)) == GS_EOF) return -7; |]
        else appendStmt [cstm| if ($id:(bufGetF)($id:global_params,
                                   $id:buf_context,
                                   $ptr) == GS_EOF) return -7; |]
      action


squashedQueueType :: Int -> Ty -> Ty
-- | Squash a queue type to expose an array of base elements
squashedQueueType 1 t = t
squashedQueueType n (TArray (Literal m) bt) = TArray (Literal (n*m)) bt
squashedQueueType n t = TArray (Literal n) t



{--------------- Writing to TS queues -----------------------------------------}

-- ts_put and variants are blocking
-- q_write_n :: QId -> Int -> C.Exp -> C.Stm
-- q_write_n (QId qid) n ptr = [cstm| ts_putMany($int:qid,$int:n,$ptr); |]

-- -- ts_put and variants are blocking
-- q_write_n_bits :: QId -> Int -> C.Exp -> C.Stm
-- q_write_n_bits (QId qid) n ptr = [cstm| ts_putManyBits($int:qid,$int:n,$ptr); |]


-- writeToTs :: DynFlags 
--            -> Int -> Ty -- # number of writes, and type of each write
--            -> QId       -- Queue id
--            -> C.Exp     -- Source variable to read from
--            -> Cg ()
-- writeToTs _ n TBit q ptr = appendStmt $ q_write_n_bits q n ptr
-- writeToTs dfs n (TArray (Literal m) TBit) q@(QId qid) ptr
--   | m `mod` 8 == 0 = appendStmt $ q_write_n q n ptr
--   | n == 1 = appendStmt $ q_write_n q 1 ptr
--   | otherwise -- Not byte-aligned byte array, a bit sad and slow
--   = do x <- CgMonad.freshName "q_rdx" (TArray (Literal m) TBit) Mut 
--        i <- CgMonad.freshName "q_idx" tint Mut
--        cgMutBind dfs noLoc i Nothing $ do 
--        cgMutBind dfs noLoc x Nothing $ do
--          cx <- lookupVarEnv x
--          ci <- lookupVarEnv i
--          -- ts_put and variants are blocking
--          appendStmt $ [cstm| for ($ci = 0; $ci < $int:n; $ci++) {
--                                 bitArrRead((typename BitArrPtr) $ptr,
--                                             $ci*$int:m,
--                                             $int:m,
--                                            (typename BitArrPtr) $cx);
--                                 ts_put($int:qid,(char *) $cx);
--                              }|]

-- writeToTs _ n _ q ptr = appendStmt $ q_write_n q n ptr


cgOutWiring :: DynFlags 
            -> QueueInfo
            -> [(Int,EId)] -- Output wires
            -> [EId]       -- Where to read from
            -> Cg a
            -> Cg a
cgOutWiring dfs qs ws vs action = go ws vs
  where 
    go [] [] = action 
    go (wir:wirs) (src:srcs) = cgOutWire dfs qs wir src (go wirs srcs)
    go _ _ = error "cgOutWiring!"

cgOutWire :: DynFlags -> QueueInfo -> (Int,EId) -> EId -> Cg a -> Cg a
cgOutWire _dfs qs (n,qvar) v action
  = case qiQueueId qvar qs of

      -- Not a queue
      Nothing ->
         assert "cgOutWire/non-queue" (n == 1) $
         assert "cgOutWire/not-same-var" (qvar == v) $ action

         -- unless (qvar == v) $
         -- void $ codeGenExp dfs (eAssign noLoc (eVar noLoc qvar) (eVar noLoc v))

      -- Some intermediate SORA queue
      Just (QMid (QId qid))
        | isSingleThreadIntermQueue qs qvar
        -> cgDeclQPtr v $ \ptr ptr_ty -> do
             appendStmt [cstm| $ptr = ($ty:ptr_ty) _stq_reserve($id:(cQPtr qid),$int:n);|]
             a <- action
             appendStmt [cstm| _stq_push($id:(cQPtr qid),$int:n);|]
             return a
        | otherwise 
        -> cgDeclQPtr v $ \ptr ptr_ty -> do
             appendStmt [cstm| $ptr = ($ty:ptr_ty) s_ts_reserve($id:(cQPtr qid),$int:n);|]
             a <- action
             appendStmt [cstm| s_ts_push($id:(cQPtr qid), $int:n);|]
             return a

      -- Unexpected input queue
      Just QIn -> panicStr "cg_out_wire: encountered the input queue!"

      -- The actual output queue
      Just QOut -> do

        a <- action

        let qtype = squashedQueueType n (nameTyp qvar)

        cgIO $ print $ vcat [ text "Out-Wiring:"
                            , text "Queue type:" <+> ppr (nameTyp qvar)
                            , text "  Squashed:" <+> ppr qtype
                            , text "  Var type:" <+> ppr (nameTyp v) ]


        let (bufput_suffix, putLen) = getTyPutGetInfo qtype
        let bufPutF = "buf_put" ++ bufput_suffix

        buf_context   <- getBufContext
        global_params <- getGlobalParams

        cv <- lookupVarEnv v
        let ptr = if isPtrType (nameTyp v)
                  then [cexp| $cv|] else [cexp| & $cv|]

        if isArrayTy qtype 
          then 
            appendStmt [cstm| $id:(bufPutF)($id:global_params,
                                            $id:buf_context,
                                            $ptr, $(putLen)); |]
          else
            appendStmt [cstm| $id:(bufPutF)($id:global_params,
                                            $id:buf_context,
                                            *$ptr); |]
        return a
        
