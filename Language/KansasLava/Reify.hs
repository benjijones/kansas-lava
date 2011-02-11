{-# LANGUAGE TypeFamilies, FlexibleInstances, FlexibleContexts, ParallelListComp, ScopedTypeVariables #-}
module Language.KansasLava.Reify
        ( reifyCircuit
        , Ports(..)
        , Input(..)
        , probe
        , probeWholeCircuit
        , output
        ) where

import Data.Default
import Data.List as L
import qualified Data.Map as Map
import Data.Reify

import Language.KansasLava.Circuit.Depth
import Language.KansasLava.Circuit.Optimization
-- import Language.KansasLava.Entity
import Language.KansasLava.Deep
import Language.KansasLava.Shallow
import Language.KansasLava.Comb
import Language.KansasLava.Seq
import Language.KansasLava.Signal
import qualified Language.KansasLava.Stream as Stream
import Language.KansasLava.Types hiding (inputs,outputs)
import qualified Language.KansasLava.Types as Trace
import Language.KansasLava.Utils
import Language.KansasLava.HandShake

import qualified Data.Sized.Matrix as M


-- | 'reifyCircuit' does reification on a function into a 'Circuit'.
--
reifyCircuit :: (Ports a) => a -> IO Circuit
reifyCircuit circuit = do

        let opts = []
        -- GenSym for input/output pad names
        -- let inputNames = L.zipWith OVar [0..] $ head $
        --         [[ "i" ++ show (i::Int) | i <- [0..]]]
        let outputNames =  L.zipWith OVar [0..] $ head $
                 [[ "o" ++ show (i::Int) | i <- [0..]]]

        let os = ports 0 circuit

        let o = Port ("o0")
                $ E
                $ Entity (Name "Lava" "top") [("o0",B)] -- not really a Bit
                [ ("i" ++ show i,tys, dr)
                | (i::Int,(tys,dr)) <- zip [0..] os
                ]

        -- Get the graph, and associate the output drivers for the graph with
        -- output pad names.
        (gr, outputs) <- case o of
                Port _ o' -> do
                   (Graph gr out) <- reifyGraph o'
                   let gr' = [ (nid,nd) | (nid,nd) <- gr
                                        , nid /= out
                             ]
                   case lookup out gr of
                     Just (Entity (Name "Lava" "top")  _ ins) ->
                       return $ (gr',[(sink,ity, driver)
                                       | (_,ity,driver) <- ins
                                       | sink <- outputNames
                                       ])
                     -- if the circuit is trivial??
                     Just (Entity (Name _ _) outs _) ->
                       return $ (gr', [(sink,oty, Port ovar out)
                                      | (ovar,oty) <- outs
                                      | sink <- outputNames
                                      ])
                     _ -> error $ "reifyCircuit: " ++ show o
                -- TODO: restore this
--                (Lit x) -> return ([],[((head outputNames),ty,Lit x)])
                v -> fail $ "reifyGraph failed in reifyCircuit" ++ show v

--      print outputs

        let newOut = 1 + maximum ((-1) : [ i | (OVar i _,_,_) <- outputs ])
--      print newOut

        let backoutputs =
              [ (OVar n ("b" ++ show n), vTy, dr)
              | (_,Entity (Prim "hof") _ [(_,vTy,dr)]) <- gr
              | n <- [newOut..]
              ]

        -- let outputs2 = outputs ++ backoutputs
        -- let outputs = outputs2
        -- outputs <- return $ outputs ++ backoutputs
        let outputsWithBack = outputs ++ backoutputs

        let hofs =
              [ i
              | (i,Entity (Prim "hof") _ [(_,_,_)])  <- gr
              ]
--      print hofs

        let findHof i = case Prelude.lookup i (zip hofs [newOut..]) of
                           Nothing -> error $ "can not find hof : " ++ show i
                           Just v -> OVar v ("o" ++ show v)


        let remap_hofs (nm,ty,Port pnm i)
                | i `elem` hofs = (nm,ty,Pad $ findHof i)
                | otherwise = (nm,ty,Port pnm i)
            remap_hofs other = other


        -- Remove hofs
        let grNoHofs = [ ( i
                         , case g of
                             Entity nm outs ins ->
                               Entity nm outs (map remap_hofs ins)
                         )
                         | (i,g) <- gr
                       , not (i `elem` hofs)
                       ]
        -- let gr = gr'

        -- Search all of the enities, looking for input ports.
        let inputs = [ (v,vTy) | (_,Entity _ _ ins) <- grNoHofs
                               , (_,vTy,Pad v) <- ins]

        let rCit = Circuit { theCircuit = grNoHofs
                                  , theSrcs = nub inputs
                                  , theSinks = outputsWithBack
                                  }


        let rCitNamesResolved = resolveNames rCit
        -- let rCit = rCit'

--      print rCit
        -- TODO remove, its a seperate pass
        rCit2 <-
          if OptimizeReify `elem` opts
            then optimizeCircuit def rCitNamesResolved
            else return rCitNamesResolved

        let depthss = [ mp | CommentDepth mp <- opts ]

        -- TODO likewisse, remove, its a seperate pass
        rCit3 <- case depthss of
{-
                    [depths]  -> do let chains = findChains (depths ++ depthTable) rCit2
                                        env = Map.fromList [ (u,d) | (d,u) <- concat chains ]
                                    return $ rCit2 { theCircuit = [ (u,case e of
                                                          Entity nm ins outs ann ->
                                                                case Map.lookup u env of
                                                                  Nothing -> e
                                                                  Just d -> Entity nm ins outs (ann ++ [Comment $ "depth: " ++ show d])
                                                          _ -> e)
                                                     | (u,e) <- theCircuit rCit2
                                                     ]}
-}
                    []        -> return rCit2


        let domains = nub $ concat $ visitEntities rCit3 $ \ _ (Entity _ _ outs) ->
                return [ nm | (_,ClkDomTy,ClkDom nm) <- outs ]

        -- The clock domains
--      print domains

        -- let nameEnv "unit" nm = nm
        --     nameEnv dom    nm = dom ++ "_" ++ nm

        -- let extraSrcs =
        --         concat [  [ nameEnv dom "clk", nameEnv dom "clk_en", nameEnv dom "rst" ]
        --                | dom <- domains
        --                ] `zip` [-1::Int,-2..]



        -- let allocs = allocEntities rCit3                    -
        let envIns = [("clk_en",B),("clk",ClkTy),("rst",B)]     -- in reverse order for a reason


	let domToPorts =
		[ (dom, [ (nm,ty,Pad (OVar idx nm))
		       | ((nm,ty),idx) <- zip envIns [i*3-1,i*3-2,i*3-3]
		       ])
		| (dom,i) <- zip domains [0,-1..]
                ]
{-
        let envSrcs = [ ( dom
                        , u
                        , Entity (Prim "Env")
                               [ ("env",ClkDomTy) ]
                               [ (nm,ty,Pad (OVar i nm)) | ((nm,ty),i) <- zip envIns [i*3-1,i*3-2,i*3-3]]
                        )
                      | (u,dom,i) <- zip3 allocs domains [0,-1..]
                     ] :: [(String,Unique,Entity Unique)]
-}
        let rCit4 = rCit3 { theCircuit =
--                                [ (u,e) | (_,u,e) <- envSrcs ] ++
                                [  (u,case e of
                                        Entity nm outs ins -> Entity
                                                nm
                                                outs
						(concat
                                                [ case p of
                                                   (_,ClkDomTy,ClkDom cdnm) ->
							case lookup cdnm domToPorts of
							   Nothing -> error $ "can not find port: " ++ show cdnm
							   Just outs' -> outs'
                                                   _ -> [p]
                                                | p <- ins ])
                                    )
                                | (u,e) <- theCircuit rCit3 ]
                          , theSrcs =
                                [ (ovar,ty) | (_,outs) <- domToPorts
					    , (_,ty,Pad ovar) <- outs
				] ++
                                theSrcs rCit3
                          }


--      print $ theSrcs rCit3

--      let rCit4 = rCir3 {




        return $ rCit4





wireCapture :: forall w . (Rep w) => D w -> [(Type, Driver E)]
wireCapture (D d) = [(repType (Witness :: Witness w), d)]


-- showCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO String
-- showCircuit _ c = do
--         rCir <- reifyCircuit c
--         return $ show rCir

-- debugCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO ()
-- debugCircuit opt c = showCircuit opt c >>= putStr

insertProbe :: ProbeName -> TraceStream -> Driver E -> Driver E
insertProbe n s@(TraceStream ty _) = mergeNested
    where mergeNested :: Driver E -> Driver E
          mergeNested (Port nm (E (Entity (TraceVal names strm) outs ins)))
                        = Port nm (E (Entity (TraceVal (n:names) strm) outs ins))
          mergeNested d = Port "o0" (E (Entity (TraceVal [n] s) [("o0",ty)] [("i0",ty,d)]))

-- this is the public facing method for probing
probe :: (Ports a) => String -> a -> a
probe name = probe' [ Probe name i 0 | i <- [0..] ]

-- used to make traces
probeWholeCircuit :: (Ports a) => a -> a
probeWholeCircuit = probe' [ WholeCircuit "" i 0 | i <- [0..] ]

-- | The 'Ports' class generates input pads for a function type, so that the
-- function can be Reified. The result of the circuit, as a driver, as well as
-- the result's type, are returned. I _think_ this takes the place of the REIFY
-- typeclass, but I'm not really sure.
class Ports a where
    ports :: Int -> a -> [(Type, Driver E)]

    -- probe' is used internally for a name supply.
    probe' :: [ProbeName] -> a -> a

    run :: a -> Trace -> TraceStream

instance (Clock c, Rep a) => Ports (CSeq c a) where
    ports _ sig = wireCapture (seqDriver sig)

    probe' (n:_) (Seq s (D d)) = Seq s (D (insertProbe n strm d))
        where strm = toTrace s
    probe' [] (Seq _ _) = error "probe'2"

    run (Seq s _) (Trace c _ _ _) = TraceStream ty $ takeMaybe c strm
        where TraceStream ty strm = toTrace s

instance Rep a => Ports (Comb a) where
    ports _ sig = wireCapture (combDriver sig)

    probe' (n:_) (Comb s (D d)) = Comb s (D (insertProbe n strm d))
        where strm = toTrace $ Stream.fromList $ repeat s

    run (Comb s _) (Trace c _ _ _) = TraceStream ty $ takeMaybe c strm
        where TraceStream ty strm = toTrace $ Stream.fromList $ repeat s

-- Need to add the clock
instance (Clock clk, Rep a) => Input (HandShaken clk (Seq a)) where
    inPorts v =  (fn , v)
        -- We need the ~ because the output does not need to depend on the input
        where fn = HandShaken $ \ ~(Seq _ ae) -> deepSeq $ entity1 (Prim "hof") $ ae
    input _ a = a
    getSignal _ = error "Can't getSignal from Handshaken"
    apply _ _ = error "Can't apply to Handshaken"


{-
instance Clock clk => Ports (Env clk) where
    probe' is name (Env clk rst clk_en) = Env clk rst' clk_en'
        where (rst',clk_en') = unpack $ probe' is name $ (pack (rst, clk_en) :: CSeq clk (Bool, Bool))
-}

addSuffixToProbeNames :: [ProbeName] -> String -> [ProbeName]
addSuffixToProbeNames pns suf = [ case pn of
                                        Probe name a i -> Probe (name ++ suf) a i
                                        WholeCircuit s a i -> WholeCircuit (s ++ suf) a i
                                | pn <- pns ]

instance (Ports a, Ports b) => Ports (a,b) where
    ports _ (a,b) = ports bad b ++ ports bad a
        where bad = error "bad using of arguments in Reify"

    probe' names (x,y) = (probe' (addSuffixToProbeNames names "-fst") x,
                          probe' (addSuffixToProbeNames names "-snd") y)

    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y) t = TraceStream (TupleTy [ty1,ty2]) $ zipWith appendRepValue strm1 strm2
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t

instance (Clock clk, Ports a) => Ports (HandShaken clk a) where
    ports vs (HandShaken f) = ports vs f
    probe' names (HandShaken f) = HandShaken $ \ ready ->
                        let ready' = probe' (addSuffixToProbeNames names "-arg") ready
                        in probe' (addSuffixToProbeNames names "-res") (f ready')

    run _ _ = error "run not defined for HandShaken"

instance (Ports a, Ports b, Ports c) => Ports (a,b,c) where
    ports _ (a,b,c) = ports bad c ++ ports bad b ++ ports bad a
        where bad = error "bad using of arguments in Reify"

    probe' names (x,y,z) = (probe' (addSuffixToProbeNames names "-fst") x,
                            probe' (addSuffixToProbeNames names "-snd") y,
                            probe' (addSuffixToProbeNames names "-thd") z)

    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y,z) t = TraceStream (TupleTy [ty1,ty2,ty3]) (zipWith appendRepValue strm1 $ zipWith appendRepValue strm2 strm3)
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t
              TraceStream ty3 strm3 = run z t

instance (Ports a,M.Size x) => Ports (M.Matrix x a) where
    ports _ m = concatMap (ports (error "bad using of arguments in Reify")) $ M.toList m
    probe' _ _ = error "Ports(probe') not defined for Matrix"
    run _ _ = error "Ports(run) not defined for Matrix"

-- Idealy we'd want this to only have the constraint: (Input a, Ports b)
-- but haven't figured out a refactoring that allows that yet. As it is,
-- Ports is a superset of Input, so this shouldn't matter.
instance (Input a, Ports a, Ports b) => Ports (a -> b) where
    ports vs f = ports vs' $ f a
        where (a,vs') = inPorts vs

    probe' (n:ns) f x = probe' ns $ f (probe' [n] x)
--    probe' names f x = probe' (addSuffixToProbeNames names "-fn") $ f (probe' (addSuffixToProbeNames names "-arg") x)

    run fn t@(Trace _ ins _ _) = run fn' $ t { Trace.inputs = ins' }
        where (ins', fn') = apply ins fn

-- TO remove when Input a, Ports b => .. works
instance Ports () where
    ports _ _ = []
    probe' _ _ = error "Ports(probe') not defined for ()"
    run _ _ = error "Ports(run) not defined for ()"


--class OutPorts a where
--    outPorts :: a ->  [(Var, Type, Driver E)]


{-
input nm = liftS1 $ \ (Comb a d) ->
        let res  = Comb a $ D $ Port ("o0") $ E $ entity
            entity = Entity (Name "Lava" "input")
                    [("o0", bitTypeOf res)]
                    [(nm, bitTypeOf res, unD d)]
                    []
        in res

-}

wireGenerate :: Int -> (D w,Int)
wireGenerate v = (D (Pad (OVar v ("i" ++ show v))),succ v)

class Input a where
    inPorts :: Int -> (a, Int)

    getSignal :: TraceStream -> a
--    getSignal _ = error "Input: getSignal, no instance"

    apply :: TraceMap -> (a -> b) -> (TraceMap, b)
--    apply _ _ = error "Input: apply, no instance"

    input :: String -> a -> a

-- Royale Hack, but does work.
instance (Rep a, Rep b) => Input (CSeq c a -> CSeq c b) where
        inPorts v =  (fn , v)
          where fn ~(Seq _ ae) = deepSeq $ entity1 (Prim "hof") $ ae

        input _ a = a
        getSignal _ = error "Input(getSignal) not defined for  Input (CSeq c a -> CSeq c b)"
        apply _ _ = error "Input(apply) not defined for  Input (CSeq c a -> CSeq c b)"


instance Rep a => Input (CSeq c a) where
    inPorts vs = (Seq (error "Input (Seq a)") d,vs')
      where (d,vs') = wireGenerate vs

    getSignal ts = shallowSeq $ fromTrace ts
    apply m fn = (Map.deleteMin m, fn $ getSignal strm)
        where strm = head $ Map.elems m

    input nm = liftS1 (input nm)

instance Rep a => Input (Comb a) where
    inPorts vs = (deepComb d,vs')
      where (d,vs') = wireGenerate vs

    getSignal ts = shallowComb $ Stream.head $ fromTrace ts
    apply m fn = (Map.deleteMin m, fn $ getSignal strm)
        where strm = head $ Map.elems m

    input nm a = label nm a
{-
(Comb a d) =
        let res  = Comb a $ D $ Port ("o0") $ E $ entity
            entity = Entity (Name "Lava" "input")
                    [("o0", bitTypeOf res)]
                    [(nm, bitTypeOf res, unD d)]
                    []
        in res
-}

{-
instance Input (Clock clk) where
    inPorts vs = (Clock (error "Input (Clock clk)") d,vs')
      where (d,vs') = wireGenerate vs

    input nm (Clock f d) =
        let res  = Clock f $ D $ Port ("o0") $ E $ entity
            entity = Entity (Label "clk")
                    [("o0", ClkTy)]
                    [(nm, ClkTy, unD d)]
                    []
        in res
-}
{-
instance Input (Env clk) where
    inPorts vs0 = (Env clk' (label "rst" rst) (label "clk_en" en),vs3)
         where ((en,rst,Clock f clk),vs3) = inPorts vs0
               clk' = Clock f $ D $ Port ("o0") $ E
                    $ Entity (Label "clk")
                        [("o0", ClkTy)]
                        [("i0", ClkTy, unD clk)]
                        []

    getSignal ts = (toEnv (Clock 1 (D $ Error "no deep clock"))) { resetEnv = rst, enableEnv = clk_en }
        where (rst, clk_en) = unpack (shallowSeq $ fromTrace ts :: CSeq clk (Bool, Bool))

    input nm (Env clk rst en) = Env (input ("clk" ++ nm) clk)
                                    (input ("rst" ++ nm) rst)
                                    (input ("sysEnable" ++ nm) en)      -- TODO: better name than sysEnable, its really clk_en
-}

instance Input () where
    inPorts vs0 = ((),vs0)
    apply _ _ = error "Input ()"
    input _ _  = error "input ()"
    getSignal _ = error "Input(getSignal) not defined for  Input ()"



instance (Input a, Input b) => Input (a,b) where
    inPorts vs0 = ((a,b),vs2)
         where
                (b,vs1) = inPorts vs0
                (a,vs2) = inPorts vs1

    apply m fn = (m', fn (getSignal s1, getSignal s2))
        where [s1,s2] = take 2 $ Map.elems m
              m' = Map.deleteMin $ Map.deleteMin m

    input nm (a,b) = (input (nm ++ "_fst") a,input (nm ++ "_snd") b)
    getSignal _ = error "Input(getSignal) not defined for  Input (a,b)"

instance (Input a, M.Size x) => Input (M.Matrix x a) where
 inPorts vs0 = (M.matrix bs, vsX)
     where
        sz :: Int
        sz = M.size (error "sz" :: x)

        loop vs0' 0 = ([], vs0')
        loop vs0' n = (c:cs,vs2)
           where (c, vs1) = inPorts vs0'
                 (cs,vs2) = loop vs1 (n-1)

        bs :: [a]
        (bs,vsX) = loop vs0 sz
 getSignal _ = error "Input(getSignal) not defined for  Input (M.Matrix x a)"
 apply _ _ = error "Input(apply) not defined for  Input (M.Matrix x a)"
 input nm m = M.forEach m $ \ i a -> input (nm ++ "_" ++ show i) a

instance (Input a, Input b, Input c) => Input (a,b,c) where
    inPorts vs0 = ((a,b,c),vs3)
         where
                (c,vs1) = inPorts vs0
                (b,vs2) = inPorts vs1
                (a,vs3) = inPorts vs2

    apply m fn = (m', fn (getSignal s1, getSignal s2, getSignal s3))
        where [s1,s2,s3] = take 3 $ Map.elems m
              m' = Map.deleteMin $ Map.deleteMin $ Map.deleteMin m

    input nm (a,b,c) = (input (nm ++ "_fst") a,input (nm ++ "_snd") b,input (nm ++ "_thd") c)
    getSignal _ = error "Input(getSignal) not defined for  Input (a,b,c)"
---------------------------------------
{-
showOptCircuit :: (Ports circuit) => [CircuitOptions] -> circuit -> IO String
showOptCircuit opt c = do
        rCir <- reifyCircuit opt c
        let loop n cs@((nm,Opt c _):_) | and [ n == 0 | (_,Opt c n) <- take 3 cs ] = do
                 putStrLn $ "## Answer " ++ show n ++ " ##############################"
                 print c
                 return c
            loop n ((nm,Opt c v):cs) = do
                print $ "Round " ++ show n ++ " (" ++ show v ++ " " ++ nm ++ ")"
                print c
                loop (succ n) cs

        let opts = cycle [ ("opt",optimizeCircuit)
                         , ("copy",copyElimCircuit)
                         , ("dce",dceCircuit)
                         ]

        rCir' <- loop 0 (("init",Opt rCir 0) : optimizeCircuits opts rCir)
        return $ show rCir'
-}

-------------------------------------------------------------


output :: (Signal seq, Rep a)  => String -> seq a -> seq a
output nm = label nm

resolveNames :: Circuit -> Circuit
resolveNames cir
        | error1 = error $ "The generated input/output names are non distinct: " ++
                           show (map fst (theSrcs cir))
        | error3 = error "The labled input/output names are non distinct"
        | otherwise = Circuit { theCircuit = newCircuit
                                     , theSrcs = newSrcs
                                     , theSinks = newSinks
                                     }
  where
        error1 = L.length (map fst (theSrcs cir)) /= L.length (nub (map fst (theSrcs cir)))
        -- error2 =  [ v
        --                 | (_,e) <- newCircuit
        --                 , v <- case e of
        --                     Entity _ _ ins -> [ nm | (_,_,Pad nm) <- ins ]
        --                 , v `elem` oldSrcs
        --                 ]
        error3 = L.length (map fst newSrcs) /= L.length (nub (map fst newSrcs))

        newCircuit =
                [ ( u
                  , case e of
                      Entity nm outs ins ->
                        Entity nm outs [ (n,t,fnInputs p) | (n,t,p) <- ins ]
--                    Entity (Name "Lava" "input") outs [(oNm,oTy,Pad (OVar i _))] misc
--                      -> Entity (Name "Lava" "id") outs [(oNm,oTy,Pad (OVar i oNm))] misc
--                    Entity (Name "Lava" io) outs ins misc
--                      | io `elem` ["input","output"]
--                      -> Entity (Name "Lava" "id") outs ins misc
--                       other -> other
                   )
                | (u,e) <- theCircuit cir
                ]

        newSrcs :: [(OVar,Type)]
        newSrcs = [ case lookup nm mapInputs of
                       Nothing -> (nm,ty)
                       Just nm' -> (nm',ty)
                  | (nm,ty) <- theSrcs cir
                  ]

        -- Names that have been replaced.
        -- oldSrcs = [ nm
        --           | (nm,_) <- theSrcs cir
        --           , not (nm `elem` (map fst newSrcs))
        --           ]

        newSinks :: [(OVar,Type,Driver Unique)]
        newSinks = [ case dr of
                      Port _ u ->
                        case lookup u (theCircuit cir) of
                          Just (Entity (Label nm') _ _) -> (OVar i nm',ty,dr)
                          _ -> (nm,ty,dr)
                      _ -> (nm,ty,dr)
                   | (nm@(OVar i _),ty,dr) <- theSinks cir
                   ]

        -- isOutput u = case lookup u (theCircuit cir) of
        --                 Just (Entity (Name "Lava" "output") _ _) -> True
        --                 _ -> False

        fnInputs :: Driver Unique -> Driver Unique
        fnInputs (Pad p) = Pad $ case lookup p mapInputs of
                             Nothing -> p
                             Just p' -> p'
        fnInputs other = other

        mapInputs :: [(OVar,OVar)]
        mapInputs = [ (OVar i inp,OVar i nm)
                    | (_,Entity (Label nm) _ [(_,_,Pad (OVar i inp))]) <- theCircuit cir
                    ]



data CircuitOptions
        = DebugReify            -- ^ show debugging output of the reification stage
        | OptimizeReify         -- ^ perform basic optimizations
        | NoRenamingReify       -- ^ do not use renaming of variables
        | CommentDepth
              [(Id,DepthOp)]    -- ^ add comments that denote depth
        deriving (Eq, Show)
