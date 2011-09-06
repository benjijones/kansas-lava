{-# LANGUAGE TypeFamilies, ExistentialQuantification, FlexibleInstances, UndecidableInstances, FlexibleContexts, DeriveDataTypeable,
    ScopedTypeVariables, MultiParamTypeClasses, FunctionalDependencies,ParallelListComp, TypeSynonymInstances, TypeOperators  #-}
-- | KansasLava is designed for generating hardware circuits. This module
-- provides a 'Rep' class that allows us to model, in the shallow embedding of
-- KL, two important features of hardware signals. First, all signals must have
-- some static width, as they will be synthsized to a collection of hardware
-- wires. Second, a value represented by a signal may be unknown, in part or in
-- whole.
module Language.KansasLava.Rep.Class where

import Language.KansasLava.Types
import Control.Monad (liftM)
import Data.Sized.Unsigned
import Data.Sized.Ix
import GHC.Exts( IsString(..) )

-- | A 'Rep a' is an 'a' value that we 'Rep'resent, aka we can push it over a
-- wire. The general idea is that instances of Rep should have a width (for the
-- corresponding bitvector representation) and that Rep instances should be able
-- to represent the "unknown" -- X -- value. For example, Bools can be
-- represented with one bit, and the inclusion of the unknown X value
-- corresponds to three-valued logic.
class {- (Size (W w)) => -} Rep w where
    -- | the width of the represented value, as a type-level number.
    type W w

    -- | X are lifted inputs to this wire.
    data X w

    -- | check for bad things.
    unX :: X w -> Maybe w

    -- | and, put the good or bad things back.
    optX :: Maybe w -> X w

    -- | convert to binary (rep) format
    toRep   :: X w -> RepValue

    -- | convert from binary (rep) format
    fromRep :: RepValue -> X w

    -- | Each wire has a known type.
    repType :: Witness w -> Type

    -- show the value (in its Haskell form, default is the bits)
    showRep :: X w -> String
    showRep x = show (toRep x)

-- | 'Bitrep' is list of values, and their bitwise representation.
-- It is used to derive (via Template Haskell) the Rep for user Haskell datatypes.
class (Size (W a), Eq a, Rep a) => BitRep a where
   bitRep :: [(a, BitPat)]

-- BitPat is a small DSL for writing bit-patterns.
-- It is bit-endian, unlike other parts of KL.
data BitPat = BitPat Integer		-- unsign extended
	    | BitPatPlus BitPat BitPat	-- sized
	    | BitPatRepValue RepValue	-- sized
    deriving (Eq, Ord, Show)

instance Num BitPat where
    (+) = BitPatPlus
    (*) = error "(*) undefined for BitPat"
    abs = error "abs undefined for BitPat"
    signum = error "signum undefined for BitPat"
    fromInteger n = BitPat n

instance IsString BitPat where 
  fromString = bits

bits :: String -> BitPat
bits = BitPatRepValue . RepValue . map f . reverse
    where 
	f '0' = return False
	f '1' = return True
	f 'X' = Nothing
	f '_' = Nothing
	f '-' = Nothing
	f o   = error $ "bit pattern, expecting one of 01X_-, found " ++ show o

word :: forall w . (Size w) => Unsigned w -> BitPat
word = BitPatRepValue . bitPatToRepValue (size (error "witness" :: w)) . fromIntegral

widthBitPat :: BitPat -> Maybe Int
widthBitPat (BitPat {}) = Nothing
widthBitPat (BitPatPlus a b) = do
	aw <- widthBitPat a
	bw <- widthBitPat b
	return (aw + bw)
widthBitPat (BitPatRepValue (RepValue ws)) = return (length ws)

-- 
bitPatToRepValue :: Int -> BitPat -> RepValue
bitPatToRepValue n (BitPat i) = RepValue $ take n
                    			 $ map (Just . odd)
                    		 	 $ iterate (`div` (2::Integer))
					 $ i
bitPatToRepValue n e@(BitPatPlus e1 e2) =
	case (widthBitPat e1,widthBitPat e2) of
		-- reverse the order, because the DSL is bit-endian
	   (Just w1,_) -> appendRepValue (bitPatToRepValue (n - w1) e2) (bitPatToRepValue w1 e1) 
	   (_,Just w2) -> appendRepValue (bitPatToRepValue w2 e2) (bitPatToRepValue (n - w2) e1) 
	   _ -> error $ "bitPatToRepValue, unknown size of " ++ show e ++ ", expecting " ++ show n
bitPatToRepValue n (BitPatRepValue rv@(RepValue ws))
	| n == length ws = rv
	| otherwise = error $ "bitPatToRepValue, bad size of rep, expecting " ++ show n ++ ", found " ++ show (length ws)

-- | Given a witness of a representable type, generate all (2^n) possible values of that type.
allReps :: (Rep w) => Witness w -> [RepValue]
allReps w = [ RepValue (fmap Just count) | count <- counts n ]
   where
    n = repWidth w
    counts :: Int -> [[Bool]]
    counts 0 = [[]]
    counts num = [ x : xs |  xs <- counts (num-1), x <- [False,True] ]

-- | Figure out the width in bits of a type.
repWidth :: (Rep w) => Witness w -> Int
repWidth w = typeWidth (repType w)


-- | unknownRepValue returns a RepValue that is completely filled with 'X'.
unknownRepValue :: (Rep w) => Witness w -> RepValue
unknownRepValue w = RepValue [ Nothing | _ <- [1..repWidth w]]

-- | pureX lifts a value to a (known) representable value.
pureX :: (Rep w) => w -> X w
pureX = optX . Just

-- | unknownX is an unknown value of every representable type.
unknownX :: forall w . (Rep w) => X w
unknownX = optX (Nothing :: Maybe w)

-- | liftX converts a function over values to a function over possibly unknown values.
liftX :: (Rep a, Rep b) => (a -> b) -> X a -> X b
liftX f = optX . liftM f . unX



-- | showRepDefault will print a Representable value, with "?" for unknown.
-- This is not wired into the class because of the extra 'Show' requirement.
showRepDefault :: forall w. (Show w, Rep w) => X w -> String
showRepDefault v = case unX v :: Maybe w of
            Nothing -> "?"
            Just v' -> show v'

-- | Convert an integral value to a RepValue -- its bitvector representation.
toRepFromIntegral :: forall v . (Rep v, Integral v) => X v -> RepValue
toRepFromIntegral v = case unX v :: Maybe v of
                 Nothing -> unknownRepValue (Witness :: Witness v)
                 Just v' -> RepValue
                    $ take (repWidth (Witness :: Witness v))
                    $ map (Just . odd)
                    $ iterate (`div` (2::Integer))
                    $ fromIntegral v'
-- | Convert a RepValue representing an integral value to a representable value
-- of that integral type.
fromRepToIntegral :: forall v . (Rep v, Integral v) => RepValue -> X v
fromRepToIntegral r =
    optX (fmap (\ xs ->
        sum [ n
                | (n,b) <- zip (iterate (* 2) 1)
                       xs
                , b
                ])
          (getValidRepValue r) :: Maybe v)

-- | fromRepToInteger always a positve number, unknowns defin
fromRepToInteger :: RepValue -> Integer
fromRepToInteger (RepValue xs) =
        sum [ n
                | (n,b) <- zip (iterate (* 2) 1)
                       xs
                , case b of
            Nothing -> False
            Just True -> True
            Just False -> False
                ]


-- | Compare a golden value with a generated value.
cmpRep :: (Rep a) => X a -> X a -> Bool
cmpRep g v = toRep g `cmpRepValue` toRep v

-- TODO: optimize this
bitRepToRep :: forall w . (BitRep w) => X w -> RepValue
bitRepToRep w = 
	case unX w of
	  Nothing -> unknownRepValue (Witness :: Witness w)
	  Just val -> case Prelude.lookup val bitRep of
			Nothing -> unknownRepValue (Witness :: Witness w)
		        Just pat -> bitPatToRepValue (repWidth (Witness :: Witness w)) pat


-- TODO: optimize this
bitRepFromRep :: forall w . (BitRep w) => RepValue -> X w
bitRepFromRep rep =
    case [ a
	 | (a,b) <- bitRep
	 , bitPatToRepValue (repWidth (Witness :: Witness w)) b `cmpRepValue` rep
	 ] of
	[] ->    optX Nothing
	(i:_) -> optX (Just i)	-- first matches

