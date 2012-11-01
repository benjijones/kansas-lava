{-# LANGUAGE ScopedTypeVariables, GADTs, KindSignatures, RankNTypes, FlexibleInstances,
        RecursiveDo, DoRec, FlexibleContexts #-}

import Language.KansasLava
import Language.KansasLava.Fabric
import Language.KansasLava.Spark
import Language.KansasLava.VCD
import Data.Sized.Unsigned
import Data.Sized.Ix
import System.IO.Unsafe
import Data.Boolean

import Control.Monad.IO.Class
--import System.Cmd
import Debug.Trace


fab :: SuperFabric Pure ()
fab = do
    x :: Signal CLK U8 <- inStdLogicVector "x"
    y :: Signal CLK U8 <- inStdLogicVector "y"
    outStdLogicVector "z" (x + y)

{-
    v :: SignalVar CLK U8 <- newSignalVar
    () <- return $! unsafePerformIO $ print v

    writeSignalVar v x
    writeSignalVar v x
    writeSignalVar v x

    t <- readSignalVar v $ \ [a,b,c] -> a + b + c

    outStdLogicVector "t" t
-}

    BUS bus bus_writer <- bus
    VAR count :: VAR U16 <- initially 0
    outStdLogicVector "count" count

    spark $ do
        l1 <- LABEL
        putBus bus_writer count $ STEP
        count := count + 1
        GOTO l1

    bus' <- fifo bus

    VAR count2 :: VAR U16 <- initially 0
    outStdLogicVector "count2" count2

    spark $ do
        l1 <- STEP
        takeBus bus' count2 $ GOTO l1
        GOTO l1

    VAR xxx :: VAR U16 <- initially 44

    outStdLogicVector "xx" (xxx)

    pc <- spark $ do
        rec l1 <- STEP
            xxx := 10
            l2 <- STEP

            ifB (return (xxx .>. 0))
               (do xxx := xxx - 1)
               (do GOTO end)
            GOTO l2

            end <- STEP
            xxx := 999
        return ()

    outStdLogicVector "pc" pc

    VAR tick :: VAR U16 <- initially 0

    spark $ do
            tick := tick + 1
            GOTO start

    outStdLogicVector "tick" tick


    MEM a b c :: MEM X4 U8 <- memory

    outStdLogicVector "a" a

    spark $ do
            b := pureS 0
            STEP
            STEP
            STEP
            c := pureS (0,100)
            l <- STEP
            GOTO l



{- -}

--    assign xxx (xxx + 1)

    return ()

driver :: forall m . (m ~ SuperFabric Pure) => m (Seq ())
driver = do
        outStdLogicVector "x" (toS [1..200] :: Seq U8)
--        outStdLogicVector "y" (toS [99,95..0] :: Seq U8)
        consume [ IN (inStdLogicVector "xx" :: m (Seq (U16)))
{-
                , IN (inStdLogicVector "pc" :: m (Seq (U8)))
                , IN (inStdLogicVector "tick" :: m (Seq (U16)))
                , IN (inStdLogicVector "count" :: m (Seq (U16)))
                , IN (inStdLogicVector "fifo_pc" :: m (Seq (U16)))
                , IN (inStdLogicVector "count2" :: m (Seq (U16)))
-}
                , IN (inStdLogicVector "a" :: m (Seq (U8)))
                ]

main = do
--        setProbesAsTrace $ appendFile "DEBUG.out"
        resetProbesForVCD
        let Pure xs = runFabricWithDriver (observeFabric fab) driver
        print (takeS 50 xs)
        vcd <- snapProbesAsVCD
        print vcd
        writeVCDFile True 20 "foo.vcd" vcd

{-
        kleg <- reifyFabric fab
        print kleg
        writeDotCircuit "graph.dot" kleg
-}
--        system "rm graph.ps"
--        system "dot -Tps < graph.dot  > graph.ps"
--        system "open -a Skim graph.ps"

{-
data REG a where
    R :: SignalVar CLK (Enabled a) -> REG a

instance Show (REG a) where
        show (R n) = "R" ++ show n

data LABEL = L Int      deriving (Eq,Ord)

instance Show LABEL where
        show (L n) = "L" ++ show n

-- TODO: call assignable
class Variable var where  -- something that can be both read and written to
        toVAR :: (REG a,Signal CLK a) -> var a

instance Variable REG where
        toVAR (r,_) = r
instance Variable (Signal CLK) where
        toVAR (_,r) = r

data VAR a = VAR (forall (var :: * -> *) . (Variable var) => var a)

assignable :: forall a var . (Rep a, Size (W (Enabled a)), Variable var) => a -> SuperFabric Pure (var a)
assignable a = do
        var <- newSignalVar
        let f a rest = mux (isEnabled a) (rest,enabledVal a)
        sig <- readSignalVar var $ \ xs ->
                let r = register a $ foldr f r xs
                in r
        return (toVAR (R var,sig :: Signal CLK a))

-}