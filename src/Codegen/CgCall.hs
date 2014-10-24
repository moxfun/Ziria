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
{-# LANGUAGE  QuasiQuotes, GADTs, ScopedTypeVariables #-}
{-# OPTIONS_GHC -fwarn-unused-binds -Werror #-}

module CgCall
  ( codeGenCall_alloc
  , codeGenCall_store
  ) where

import Opts
import AstExpr
import AstComp
import PpExpr
import PpComp
import qualified GenSym as GS
import CgHeader
import CgRuntime
import CgMonad
import CgTypes
import CgLUT

import Text.Parsec.Pos ( SourcePos )


import Control.Applicative
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Bits
import Data.List (elemIndex, foldl', isPrefixOf )
import qualified Data.Loc
import qualified Data.Symbol
import qualified Language.C.Syntax as C
import Language.C.Quote.C
import Language.C.Quote.Base (ToConst(..))
import qualified Language.C.Pretty as P
import Numeric (showHex)
import qualified Data.Map as M
import Text.PrettyPrint.Mainland
import Data.Maybe

-- Recursive import
import CgExpr 

codeGenCall_alloc :: DynFlags 
                  -> Maybe SourcePos 
                  -> Ty 
                  -> GName Ty 
                  -> [Exp Ty] -> Cg C.Exp
-- Call function and it is your responsibility to allocate space
codeGenCall_alloc dflags loc retTy nef eargs
  = do { is_struct_ptr <- isStructPtrType retTy
       ; newNm <- freshName $ name nef ++ "_" ++ getLnNumInStr loc
        
       ; let retNewN = toName ("__retcall_" ++ name newNm) Nothing Nothing
             cer     = [cexp|$id:(name retNewN)|]

       ; appendDecls =<<
           codeGenDeclGlobalGroups dflags [(retNewN, retTy, Nothing)]

       ; codegen_call dflags loc retTy cer nef eargs 
       }

codeGenCall_store :: DynFlags
                  -> Maybe SourcePos
                  -> Ty 
                  -> C.Exp
                  -> GName Ty
                  -> [Exp Ty] -> Cg ()
-- Call function and store its result in the passed in C.Exp
codeGenCall_store dflags loc retTy cer nef eargs
  = do { _ <- codegen_call dflags loc retTy cer nef eargs
       ; return () }


codegen_call :: DynFlags
             -> Maybe SourcePos 
             -> Ty 
             -> C.Exp 
             -> GName Ty 
             -> [Exp Ty]
             -> Cg C.Exp
codegen_call dflags loc retTy cer nef eargs
  = do  -- Here first look if there is a name replacement created due to
        -- possible multiple calls of the same local function
        -- Invariant: ef = EVar nm

       is_struct_ptr <- isStructPtrType retTy

       (real_f_name, closure_params) <- lookupExpFunEnv nef
       let is_external = isPrefixOf "__ext" (name real_f_name)

       withDisabledBCWhen is_external $ do

       let cef = [cexp|$id:(name real_f_name)|]

       -- Standard function arguments
       ceargs <- concat <$> mapM (codeGenArg dflags) eargs

       -- Extra closure arguments
       let closure_args = [MkExp (EVar nm) loc ty
                               | (nm,ty) <- closure_params]
       cclosure_args <- concat <$> mapM (codeGenArgByRef dflags) closure_args

       let cargs = ceargs ++ cclosure_args

       -- [external-retf] GS: It seems like we're relying on some very tricky
       -- invariants here to ensure that cer =
       -- retf_<name-of-external-function> when the lookup comes back empty!
       -- This seems bad :-)

       case retTy of
         TArr li _ty
           | let clen = case li of Literal l -> [cexp| $int:l|]
                                   NVar c _m -> [cexp| $id:(name c)|]
           -> inAllocFrame $
              appendStmt [cstm|$(cef)($cer, $clen, $args:cargs);|]

         _ | is_struct_ptr
           -> inAllocFrame $
              appendStmt [cstm|$(cef)($cer, $args:cargs);|]

           | otherwise
          -> inAllocFrame $ 
             appendStmt [cstm| $cer = $(cef)($args:cargs);|]
       
       return [cexp|$cer|]  



codeGenArg :: DynFlags -> Exp Ty -> Cg [C.Exp]
codeGenArg dflags e = do
    ce   <- codeGenExp dflags e
    clen <- case info e of
              TArr (Literal l) _ -> return [[cexp|$int:l|]]
              TArr (NVar n _)  _ -> return [[cexp|$id:(name n)|]]
              _                  -> return []
    return $ ce : clen

codeGenArgByRef :: DynFlags -> Exp Ty -> Cg [C.Exp]
codeGenArgByRef dflags e
    | isArrTy (info e) = codeGenArg dflags e
    | otherwise
    = do { ce <- codeGenExp dflags e
         ; case ce of
             C.Var (C.Id {}) _
              -> do { alloc_as_ptr <- isStructPtrType (info e)
                    ; if alloc_as_ptr || isArrTy (info e)
                      then return [ [cexp|$ce|] ]
                      else return [ [cexp|&$ce|] ]
                    }
             _otherwise -- A bit of a weird case. Create storage and pass addr of storage
              -> do { new_tmp <- freshName "clos_ref_arg"
                    ; g <- codeGenDeclGroup (name new_tmp) (info e)
                    ; appendDecl g
                    ; assignByVal (info e) (info e) [cexp|$id:(name new_tmp)|] ce
                    ; alloc_as_ptr <- isStructPtrType (info e) -- Pointer?
                    ; if alloc_as_ptr || isArrTy (info e)
                            -- Already a ptr
                       then return [ [cexp| $id:(name new_tmp)  |] ]
                            -- Otherwise take address
                       else return [ [cexp| & $id:(name new_tmp)|] ]
                    }
         }