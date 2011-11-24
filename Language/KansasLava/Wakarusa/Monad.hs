{-# LANGUAGE GADTs, KindSignatures, RankNTypes, ScopedTypeVariables, DoRec, TypeFamilies #-}

module Language.KansasLava.Wakarusa.Monad where

import Language.KansasLava.Wakarusa.AST

import Language.KansasLava.Signal
import Language.KansasLava.Fabric
import Language.KansasLava.Rep
import Language.KansasLava.Protocols.Enabled
import Language.KansasLava.Universal
import Language.KansasLava.Utils

import Data.Sized.Ix

import Data.Map as Map

import Control.Monad.State
import Control.Monad.Reader

data WakarusaState = WakarusaState
        { ws_uniq     :: Uniq
        , ws_label    :: Maybe LABEL   
                -- ^ current thread (after GOTO this is Nothing)


        
        , ws_regs     :: Map Uniq (Pad -> Pad)
          -- ^ add the register, please, 
        , ws_assignments :: Map Uniq Pad
          -- ^ (untyped) assignments, chained into a single Seq (Enabled a).
        , ws_inputs      :: Map Uniq Pad                -- sig a

        , ws_pc       :: PC               -- ^ The PC 
        , ws_labels   :: Map LABEL PC   -- where the labels are


        , ws_pcs    :: [(PC,Maybe (Seq Bool),LABEL)]
                        -- if conditional holds, then jump to the given label
        }
--        deriving Show

-- Placeholder
{-
instance Show WakarusaState where
        show (WakarusaState u regs assignments inputs pc _ pcs) = 
                "uniq : " ++ show u ++ "\n" ++
                "regs : " ++ show (fmap (const ()) regs) ++ "\n" ++
                "assignments : " ++ show (fmap (const ()) assignments) ++ "\n" ++
                "inputs : " ++ show (fmap (const ()) inputs) ++ "\n" ++                
                "pc : " ++ show pc ++ "\n" ++
                "pcs : " ++ show (fmap (const ()) pcs)
-}

data WakarusaEnv = WakarusaEnv
        { --we_label    :: Maybe LABEL            --
{-        , -} we_pred     :: Maybe (Seq Bool)       -- optional predicate on specific instructions

        -- These are 2nd pass things
        , we_reads    :: Map Uniq Pad           -- register output  (2nd pass)
        , we_writes   :: Map Uniq Pad           -- register input   (2nd pass)
        , we_pcs      :: Map PC (Seq Bool)
                -- ^ is this instruction being executed right now?
        }
        deriving Show

------------------------------------------------------------------------------

type WakarusaComp = StateT WakarusaState (ReaderT WakarusaEnv Fabric)

------------------------------------------------------------------------------

type Uniq = Int
type PC = X256

------------------------------------------------------------------------------


getUniq :: WakarusaComp Int
getUniq = do
        st <- get
        let u = ws_uniq st + 1
        put $ st { ws_uniq = u }
        return u
        
getPC :: WakarusaComp PC
getPC = do
        st <- get
        return $ ws_pc st 
        
incPC :: WakarusaComp ()
incPC = do
        st <- get
        let pc = ws_pc st + 1
        put $ st { ws_pc = pc }
        return ()
        
recordJump :: LABEL -> WakarusaComp ()
recordJump lab =  do
        pc <- getPC
        env <- ask 
        modify (\ st -> st { ws_pcs = (pc,we_pred env,lab) : ws_pcs st })
        return ()

registerAction :: forall a . (Rep a) => REG a -> Seq Bool -> Seq a -> WakarusaComp ()
registerAction (R r) en val = do
        st <- get
        let mix :: Maybe (Seq (Enabled a)) -> Maybe (Seq (Enabled a)) -> Seq (Enabled a)
            mix (Just s1) (Just s2) = chooseEnabled s1 s2
            mix _ _ = error "failure to mix register assignments"
        let assignments = Map.insertWith (\ u1 u2 -> toUni (mix (fromUni u1) (fromUni u2)))
                                  r 
                                  (toUni $ packEnabled en val)
                                  (ws_assignments st)
        put $ st { ws_assignments = assignments }
        return ()

addRegister :: forall a. (Rep a) => REG a -> Maybe a -> WakarusaComp ()
addRegister (R k) opt_def = do
        st <- get
        let m = Map.insert k (toUni . f opt_def . fromUni) (ws_regs st)
        put $ st { ws_regs = m }
        return ()
  where
          f :: (Rep a) => Maybe a -> Maybe (Seq (Enabled a)) -> Seq a
          f Nothing    Nothing   = undefinedS              -- no assignments happen ever
          f (Just def) Nothing   = pureS def               -- no assignments happend
          f Nothing    (Just wt) = delayEnabled wt
          f (Just def) (Just wt) = registerEnabled def wt


addInput :: forall a. (Rep a) => REG a -> Seq a -> WakarusaComp ()
addInput (R k) inp = do
        st <- get
        let m = Map.insert k (toUni inp) (ws_inputs st)
        put $ st { ws_inputs = m }
        return ()

-- get the predicate for *this* instruction
getPred :: WakarusaComp (Seq Bool)
getPred = do
            pc <- getPC
            env <- ask
            return $ case Map.lookup pc (we_pcs env) of
              Nothing     -> error $ "can not find the PC predicate for " ++ show pc ++ " (no control flow to this point?)"
              Just pc_pred -> foldr1 (.&&.) $
                                [ pc_pred
                                ] ++ case we_pred env of
                                        Nothing -> []
                                        Just local_pred -> [ local_pred ]


setPred :: Seq Bool -> WakarusaComp a -> WakarusaComp a
setPred p m = local f m
  where
   f env = env { we_pred = case we_pred env of
                             Nothing -> Just p
                             Just p' -> Just (p' .&&. p)
               }

getLabel :: WakarusaComp (Maybe LABEL)
getLabel = do
        st <- get
        return $ ws_label st

getRegRead :: (Rep a) => Uniq -> WakarusaComp (Seq a)
getRegRead k = do
        env <- ask
        -- remember to return before checking error, to allow 2nd pass
        return $ case Map.lookup k (we_reads env) of
           Nothing -> error $ "getRegRead, can not find : " ++ show k
           Just p  -> case fromUni p of
                        Nothing -> error $ "getRegRead, coerce error in : " ++ show k
                        Just e -> e

getRegWrite :: forall a . (Rep a) => Uniq -> WakarusaComp (Seq (Enabled a))
getRegWrite k = do
        env <- ask
        -- remember to return before checking error, to allow 2nd pass
        return $ case Map.lookup k (we_writes env) of
           Nothing -> error $ "getRegWrite, can not find : " ++ show k
           Just p  -> case fromUni p of
                        Nothing -> error $ "getRegWrite, coerce error in : " ++ show k
                        Just e -> e


newLabel :: LABEL -> WakarusaComp ()
newLabel lab = do
        -- patch the current control to the new label
--        old_lab <- getLabel
--        case old_lab of
--          Nothing -> return ()
--          Just {} -> recordJump lab
        modify (\ st0 -> st0 { ws_labels = insert lab (ws_pc st0) (ws_labels st0) })

addToFabric :: Fabric a -> WakarusaComp a
addToFabric f = lift (lift f)

-- No more execution statements, so we unset the label
noFallThrough :: WakarusaComp ()
noFallThrough = modify (\ st -> st { ws_label = Nothing })
