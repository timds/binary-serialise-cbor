{-# LANGUAGE CPP       #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Serialise.Cborg.FlatTerm
-- Copyright   : (c) Duncan Coutts 2015-2017
-- License     : BSD3-style (see LICENSE.txt)
--
-- Maintainer  : duncan@community.haskell.org
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- A simpler form than CBOR for writing out @'Enc.Encoding'@ values that allows
-- easier verification and testing. While this library primarily focuses
-- on taking @'Enc.Encoding'@ values (independent of any underlying format)
-- and serializing them into CBOR format, this module offers an alternative
-- format called @'FlatTerm'@ for serializing @'Enc.Encoding'@ values.
--
-- The @'FlatTerm'@ form is very simple and internally mirrors the original
-- @'Encoding'@ type very carefully. The intention here is that once you
-- have @'Enc.Encoding'@ and @'Dec.Decoding'@ values for your types, you can
-- round-trip values through @'FlatTerm'@ to catch bugs more easily and with
-- a smaller amount of code to look through.
--
-- For that reason, this module is primarily useful for client libraries,
-- and even then, only for their test suites to offer a simpler form for
-- doing encoding tests and catching problems in an encoder and decoder.
--
module Serialise.Cborg.FlatTerm
  ( -- * Types
    FlatTerm      -- :: *
  , TermToken(..) -- :: *

    -- * Functions
  , toFlatTerm    -- :: Encoding -> FlatTerm
  , fromFlatTerm  -- :: Decoder s a -> FlatTerm -> Either String a
  , validFlatTerm -- :: FlatTerm -> Bool
  ) where

#include "cbor.h"

import           Serialise.Cborg.Encoding (Encoding(..))
import qualified Serialise.Cborg.Encoding as Enc
import           Serialise.Cborg.Decoding as Dec

import           Data.Int
#if defined(ARCH_32bit)
import           GHC.Int   (Int64(I64#))
import           GHC.Word  (Word64(W64#))
import           GHC.Exts  (Word64#, Int64#)
#endif
import           GHC.Word  (Word(W#), Word8(W8#))
import           GHC.Exts  (Int(I#), Int#, Word#, Float#, Double#)
import           GHC.Float (Float(F#), Double(D#), float2Double)

import           Data.Word
import           Data.Text (Text)
import           Data.ByteString (ByteString)
import           Control.Monad.ST


--------------------------------------------------------------------------------

-- | A "flat" representation of an @'Enc.Encoding'@ value,
-- useful for round-tripping and writing tests.
--
-- @since 0.2.0.0
type FlatTerm = [TermToken]

-- | A concrete encoding of @'Enc.Encoding'@ values, one
-- which mirrors the original @'Enc.Encoding'@ type closely.
--
-- @since 0.2.0.0
data TermToken
    = TkInt      {-# UNPACK #-} !Int
    | TkInteger                 !Integer
    | TkBytes    {-# UNPACK #-} !ByteString
    | TkBytesBegin
    | TkString   {-# UNPACK #-} !Text
    | TkStringBegin
    | TkListLen  {-# UNPACK #-} !Word
    | TkListBegin
    | TkMapLen   {-# UNPACK #-} !Word
    | TkMapBegin
    | TkBreak
    | TkTag      {-# UNPACK #-} !Word64
    | TkBool                    !Bool
    | TkNull
    | TkSimple   {-# UNPACK #-} !Word8
    | TkFloat16  {-# UNPACK #-} !Float
    | TkFloat32  {-# UNPACK #-} !Float
    | TkFloat64  {-# UNPACK #-} !Double
    deriving (Eq, Ord, Show)

--------------------------------------------------------------------------------

-- | Convert an arbitrary @'Enc.Encoding'@ into a @'FlatTerm'@.
--
-- @since 0.2.0.0
toFlatTerm :: Encoding -- ^ The input @'Enc.Encoding'@.
           -> FlatTerm -- ^ The resulting @'FlatTerm'@.
toFlatTerm (Encoding tb) = convFlatTerm (tb Enc.TkEnd)

convFlatTerm :: Enc.Tokens -> FlatTerm
convFlatTerm (Enc.TkWord     w  ts)
  | w <= maxInt                     = TkInt     (fromIntegral w) : convFlatTerm ts
  | otherwise                       = TkInteger (fromIntegral w) : convFlatTerm ts
convFlatTerm (Enc.TkWord64   w  ts)
  | w <= maxInt                     = TkInt     (fromIntegral w) : convFlatTerm ts
  | otherwise                       = TkInteger (fromIntegral w) : convFlatTerm ts
convFlatTerm (Enc.TkInt      n  ts) = TkInt       n : convFlatTerm ts
convFlatTerm (Enc.TkInt64    n  ts)
  | n <= maxInt && n >= minInt      = TkInt     (fromIntegral n) : convFlatTerm ts
  | otherwise                       = TkInteger (fromIntegral n) : convFlatTerm ts
convFlatTerm (Enc.TkInteger  n  ts)
  | n <= maxInt && n >= minInt      = TkInt (fromIntegral n) : convFlatTerm ts
  | otherwise                       = TkInteger   n : convFlatTerm ts
convFlatTerm (Enc.TkBytes    bs ts) = TkBytes    bs : convFlatTerm ts
convFlatTerm (Enc.TkBytesBegin  ts) = TkBytesBegin  : convFlatTerm ts
convFlatTerm (Enc.TkString   st ts) = TkString   st : convFlatTerm ts
convFlatTerm (Enc.TkStringBegin ts) = TkStringBegin : convFlatTerm ts
convFlatTerm (Enc.TkListLen  n  ts) = TkListLen   n : convFlatTerm ts
convFlatTerm (Enc.TkListBegin   ts) = TkListBegin   : convFlatTerm ts
convFlatTerm (Enc.TkMapLen   n  ts) = TkMapLen    n : convFlatTerm ts
convFlatTerm (Enc.TkMapBegin    ts) = TkMapBegin    : convFlatTerm ts
convFlatTerm (Enc.TkTag      n  ts) = TkTag (fromIntegral n) : convFlatTerm ts
convFlatTerm (Enc.TkTag64    n  ts) = TkTag       n : convFlatTerm ts
convFlatTerm (Enc.TkBool     b  ts) = TkBool      b : convFlatTerm ts
convFlatTerm (Enc.TkNull        ts) = TkNull        : convFlatTerm ts
convFlatTerm (Enc.TkUndef       ts) = TkSimple   23 : convFlatTerm ts
convFlatTerm (Enc.TkSimple   n  ts) = TkSimple    n : convFlatTerm ts
convFlatTerm (Enc.TkFloat16  f  ts) = TkFloat16   f : convFlatTerm ts
convFlatTerm (Enc.TkFloat32  f  ts) = TkFloat32   f : convFlatTerm ts
convFlatTerm (Enc.TkFloat64  f  ts) = TkFloat64   f : convFlatTerm ts
convFlatTerm (Enc.TkBreak       ts) = TkBreak       : convFlatTerm ts
convFlatTerm  Enc.TkEnd             = []

--------------------------------------------------------------------------------

-- | Given a @'Dec.Decoder'@, decode a @'FlatTerm'@ back into
-- an ordinary value, or return an error.
--
-- @since 0.2.0.0
fromFlatTerm :: (forall s. Decoder s a)
                                -- ^ A @'Dec.Decoder'@ for a serialised value.
             -> FlatTerm        -- ^ The serialised @'FlatTerm'@.
             -> Either String a -- ^ The deserialised value, or an error.
fromFlatTerm decoder ft =
    runST (getDecodeAction decoder >>= go ft)
  where
    go :: FlatTerm -> DecodeAction s a -> ST s (Either String a)
    go (TkInt     n : ts) (ConsumeWord k)
        | n >= 0                             = k (unW# (fromIntegral n)) >>= go ts
    go (TkInteger n : ts) (ConsumeWord k)
        | n >= 0                             = k (unW# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeWord8 k)
        | n >= 0 && n <= maxWord8            = k (unW# (fromIntegral n)) >>= go ts
    go (TkInteger n : ts) (ConsumeWord8 k)
        | n >= 0 && n <= maxWord8            = k (unW# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeWord16 k)
        | n >= 0 && n <= maxWord16           = k (unW# (fromIntegral n)) >>= go ts
    go (TkInteger n : ts) (ConsumeWord16 k)
        | n >= 0 && n <= maxWord16           = k (unW# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeWord32 k)
        -- NOTE: we have to be very careful about this branch
        -- on 32 bit machines, because maxBound :: Int < maxBound :: Word32
        | intIsValidWord32 n                 = k (unW# (fromIntegral n)) >>= go ts
    go (TkInteger n : ts) (ConsumeWord32 k)
        | n >= 0 && n <= maxWord32           = k (unW# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeNegWord k)
        | n <  0                             = k (unW# (fromIntegral (-1-n))) >>= go ts
    go (TkInteger n : ts) (ConsumeNegWord k)
        | n <  0                             = k (unW# (fromIntegral (-1-n))) >>= go ts
    go (TkInt     n : ts) (ConsumeInt k)     = k (unI# n) >>= go ts
    go (TkInteger n : ts) (ConsumeInt k)
        | n <= maxInt                        = k (unI# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeInt8 k)
        | n >= minInt8 && n <= maxInt8       = k (unI# n) >>= go ts
    go (TkInteger n : ts) (ConsumeInt8 k)
        | n >= minInt8 && n <= maxInt8       = k (unI# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeInt16 k)
        | n >= minInt16 && n <= maxInt16     = k (unI# n) >>= go ts
    go (TkInteger n : ts) (ConsumeInt16 k)
        | n >= minInt16 && n <= maxInt16     = k (unI# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeInt32 k)
        | n >= minInt32 && n <= maxInt32     = k (unI# n) >>= go ts
    go (TkInteger n : ts) (ConsumeInt32 k)
        | n >= minInt32 && n <= maxInt32     = k (unI# (fromIntegral n)) >>= go ts
    go (TkInt     n : ts) (ConsumeInteger k) = k (fromIntegral n) >>= go ts
    go (TkInteger n : ts) (ConsumeInteger k) = k n >>= go ts
    go (TkListLen n : ts) (ConsumeListLen k)
        | n <= maxInt                        = k (unI# (fromIntegral n)) >>= go ts
    go (TkMapLen  n : ts) (ConsumeMapLen  k)
        | n <= maxInt                        = k (unI# (fromIntegral n)) >>= go ts
    go (TkTag     n : ts) (ConsumeTag     k)
        | n <= maxWord                       = k (unW# (fromIntegral n)) >>= go ts

#if defined(ARCH_32bit)
    -- 64bit variants for 32bit machines
    go (TkInt       n : ts) (ConsumeWord64    k)
      | n >= 0                                   = k (unW64# (fromIntegral n)) >>= go ts
    go (TkInteger   n : ts) (ConsumeWord64    k)
      | n >= 0                                   = k (unW64# (fromIntegral n)) >>= go ts
    go (TkInt       n : ts) (ConsumeNegWord64 k)
      | n < 0                                    = k (unW64# (fromIntegral (-1-n))) >>= go ts
    go (TkInteger   n : ts) (ConsumeNegWord64 k)
      | n < 0                                    = k (unW64# (fromIntegral (-1-n))) >>= go ts

    go (TkInt       n : ts) (ConsumeInt64     k) = k (unI64# (fromIntegral n)) >>= go ts
    go (TkInteger   n : ts) (ConsumeInt64     k) = k (unI64# (fromIntegral n)) >>= go ts

    go (TkTag       n : ts) (ConsumeTag64     k) = k (unW64# n) >>= go ts

    -- TODO FIXME (aseipp/dcoutts): are these going to be utilized?
    -- see fallthrough case below if/when fixed.
    go ts (ConsumeListLen64 _)                   = unexpected "decodeListLen64" ts
    go ts (ConsumeMapLen64  _)                   = unexpected "decodeMapLen64"  ts
#endif

    go (TkFloat16 f : ts) (ConsumeFloat  k) = k (unF# f) >>= go ts
    go (TkFloat32 f : ts) (ConsumeFloat  k) = k (unF# f) >>= go ts
    go (TkFloat16 f : ts) (ConsumeDouble k) = k (unD# (float2Double f)) >>= go ts
    go (TkFloat32 f : ts) (ConsumeDouble k) = k (unD# (float2Double f)) >>= go ts
    go (TkFloat64 f : ts) (ConsumeDouble k) = k (unD# f) >>= go ts
    go (TkBytes  bs : ts) (ConsumeBytes  k) = k bs >>= go ts
    go (TkString st : ts) (ConsumeString k) = k st >>= go ts
    go (TkBool    b : ts) (ConsumeBool   k) = k b >>= go ts
    go (TkSimple  n : ts) (ConsumeSimple k) = k (unW8# n) >>= go ts

    go (TkBytesBegin  : ts) (ConsumeBytesIndef   da) = da >>= go ts
    go (TkStringBegin : ts) (ConsumeStringIndef  da) = da >>= go ts
    go (TkListBegin   : ts) (ConsumeListLenIndef da) = da >>= go ts
    go (TkMapBegin    : ts) (ConsumeMapLenIndef  da) = da >>= go ts
    go (TkNull        : ts) (ConsumeNull         da) = da >>= go ts

    go (TkListLen n : ts) (ConsumeListLenOrIndef k)
        | n <= maxInt                               = k (unI# (fromIntegral n)) >>= go ts
    go (TkListBegin : ts) (ConsumeListLenOrIndef k) = k (-1#) >>= go ts
    go (TkMapLen  n : ts) (ConsumeMapLenOrIndef  k)
        | n <= maxInt                               = k (unI# (fromIntegral n)) >>= go ts
    go (TkMapBegin  : ts) (ConsumeMapLenOrIndef  k) = k (-1#) >>= go ts
    go (TkBreak     : ts) (ConsumeBreakOr        k) = k True >>= go ts
    go ts@(_        : _ ) (ConsumeBreakOr        k) = k False >>= go ts

    go ts@(tk:_) (PeekTokenType k) = k (tokenTypeOf tk) >>= go ts
    go ts        (PeekTokenType _) = unexpected "peekTokenType" ts
    go ts        (PeekAvailable k) = k (unI# (length ts)) >>= go ts

    go _  (Fail msg) = return $ Left msg
    go [] (Done x)   = return $ Right x
    go ts (Done _)   = return $ Left ("trailing tokens: " ++ show (take 5 ts))

    ----------------------------------------------------------------------------
    -- Fallthrough cases: unhandled token/DecodeAction combinations

    go ts (ConsumeWord    _) = unexpected "decodeWord"    ts
    go ts (ConsumeWord8   _) = unexpected "decodeWord8"   ts
    go ts (ConsumeWord16  _) = unexpected "decodeWord16"  ts
    go ts (ConsumeWord32  _) = unexpected "decodeWord32"  ts
    go ts (ConsumeNegWord _) = unexpected "decodeNegWord" ts
    go ts (ConsumeInt     _) = unexpected "decodeInt"     ts
    go ts (ConsumeInt8    _) = unexpected "decodeInt8"    ts
    go ts (ConsumeInt16   _) = unexpected "decodeInt16"   ts
    go ts (ConsumeInt32   _) = unexpected "decodeInt32"   ts
    go ts (ConsumeInteger _) = unexpected "decodeInteger" ts

    go ts (ConsumeListLen _) = unexpected "decodeListLen" ts
    go ts (ConsumeMapLen  _) = unexpected "decodeMapLen"  ts
    go ts (ConsumeTag     _) = unexpected "decodeTag"     ts

    go ts (ConsumeFloat  _) = unexpected "decodeFloat"  ts
    go ts (ConsumeDouble _) = unexpected "decodeDouble" ts
    go ts (ConsumeBytes  _) = unexpected "decodeBytes"  ts
    go ts (ConsumeString _) = unexpected "decodeString" ts
    go ts (ConsumeBool   _) = unexpected "decodeBool"   ts
    go ts (ConsumeSimple _) = unexpected "decodeSimple" ts

#if defined(ARCH_32bit)
    -- 64bit variants for 32bit machines
    go ts (ConsumeWord64    _) = unexpected "decodeWord64"    ts
    go ts (ConsumeNegWord64 _) = unexpected "decodeNegWord64" ts
    go ts (ConsumeInt64     _) = unexpected "decodeInt64"     ts
    go ts (ConsumeTag64     _) = unexpected "decodeTag64"     ts
  --go ts (ConsumeListLen64 _) = unexpected "decodeListLen64" ts
  --go ts (ConsumeMapLen64  _) = unexpected "decodeMapLen64"  ts
#endif

    go ts (ConsumeBytesIndef   _) = unexpected "decodeBytesIndef"   ts
    go ts (ConsumeStringIndef  _) = unexpected "decodeStringIndef"  ts
    go ts (ConsumeListLenIndef _) = unexpected "decodeListLenIndef" ts
    go ts (ConsumeMapLenIndef  _) = unexpected "decodeMapLenIndef"  ts
    go ts (ConsumeNull         _) = unexpected "decodeNull"         ts

    go ts (ConsumeListLenOrIndef _) = unexpected "decodeListLenOrIndef" ts
    go ts (ConsumeMapLenOrIndef  _) = unexpected "decodeMapLenOrIndef"  ts
    go ts (ConsumeBreakOr        _) = unexpected "decodeBreakOr"        ts

    unexpected name []      = return $ Left $ name ++ ": unexpected end of input"
    unexpected name (tok:_) = return $ Left $ name ++ ": unexpected token " ++ show tok

-- | Map a @'TermToken'@ to the underlying CBOR @'TokenType'@
tokenTypeOf :: TermToken -> TokenType
tokenTypeOf (TkInt n)
    | n >= 0                = TypeUInt
    | otherwise             = TypeNInt
tokenTypeOf TkInteger{}     = TypeInteger
tokenTypeOf TkBytes{}       = TypeBytes
tokenTypeOf TkBytesBegin{}  = TypeBytesIndef
tokenTypeOf TkString{}      = TypeString
tokenTypeOf TkStringBegin{} = TypeStringIndef
tokenTypeOf TkListLen{}     = TypeListLen
tokenTypeOf TkListBegin{}   = TypeListLenIndef
tokenTypeOf TkMapLen{}      = TypeMapLen
tokenTypeOf TkMapBegin{}    = TypeMapLenIndef
tokenTypeOf TkTag{}         = TypeTag
tokenTypeOf TkBool{}        = TypeBool
tokenTypeOf TkNull          = TypeNull
tokenTypeOf TkBreak         = TypeBreak
tokenTypeOf TkSimple{}      = TypeSimple
tokenTypeOf TkFloat16{}     = TypeFloat16
tokenTypeOf TkFloat32{}     = TypeFloat32
tokenTypeOf TkFloat64{}     = TypeFloat64

--------------------------------------------------------------------------------

-- | Ensure a @'FlatTerm'@ is internally consistent and was created in a valid
-- manner.
--
-- @since 0.2.0.0
validFlatTerm :: FlatTerm -- ^ The input @'FlatTerm'@
              -> Bool     -- ^ @'True'@ if valid, @'False'@ otherwise.
validFlatTerm ts =
   either (const False) (const True) $ do
     ts' <- validateTerm TopLevelSingle ts
     case ts' of
       [] -> return ()
       _  -> Left "trailing data"

-- | A data type used for tracking the position we're at
-- as we traverse a @'FlatTerm'@ and make sure it's valid.
data Loc = TopLevelSingle
         | TopLevelSequence
         | InString   Int     Loc
         | InBytes    Int     Loc
         | InListN    Int Int Loc
         | InList     Int     Loc
         | InMapNKey  Int Int Loc
         | InMapNVal  Int Int Loc
         | InMapKey   Int     Loc
         | InMapVal   Int     Loc
         | InTagged   Word64  Loc
  deriving Show

-- | Validate an arbitrary @'FlatTerm'@ at an arbitrary location.
validateTerm :: Loc -> FlatTerm -> Either String FlatTerm
validateTerm _loc (TkInt       _   : ts) = return ts
validateTerm _loc (TkInteger   _   : ts) = return ts
validateTerm _loc (TkBytes     _   : ts) = return ts
validateTerm  loc (TkBytesBegin    : ts) = validateBytes loc 0 ts
validateTerm _loc (TkString    _   : ts) = return ts
validateTerm  loc (TkStringBegin   : ts) = validateString loc 0 ts
validateTerm  loc (TkListLen   len : ts)
    | len <= maxInt                      = validateListN loc 0 (fromIntegral len) ts
    | otherwise                          = Left "list len too long (> max int)"
validateTerm  loc (TkListBegin     : ts) = validateList  loc 0     ts
validateTerm  loc (TkMapLen    len : ts)
    | len <= maxInt                      = validateMapN  loc 0 (fromIntegral len) ts
    | otherwise                          = Left "map len too long (> max int)"
validateTerm  loc (TkMapBegin      : ts) = validateMap   loc 0     ts
validateTerm  loc (TkTag       w   : ts) = validateTerm  (InTagged w loc) ts
validateTerm _loc (TkBool      _   : ts) = return ts
validateTerm _loc (TkNull          : ts) = return ts
validateTerm  loc (TkBreak         : _)  = unexpectedToken TkBreak loc
validateTerm _loc (TkSimple  _     : ts) = return ts
validateTerm _loc (TkFloat16 _     : ts) = return ts
validateTerm _loc (TkFloat32 _     : ts) = return ts
validateTerm _loc (TkFloat64 _     : ts) = return ts
validateTerm  loc                    []  = unexpectedEof loc

unexpectedToken :: TermToken -> Loc -> Either String a
unexpectedToken tok loc = Left $ "unexpected token " ++ show tok
                              ++ ", in context " ++ show loc

unexpectedEof :: Loc -> Either String a
unexpectedEof loc = Left $ "unexpected end of input in context " ++ show loc

validateBytes :: Loc -> Int -> [TermToken] -> Either String [TermToken]
validateBytes _    _ (TkBreak   : ts) = return ts
validateBytes ploc i (TkBytes _ : ts) = validateBytes ploc (i+1) ts
validateBytes ploc i (tok       : _)  = unexpectedToken tok (InBytes i ploc)
validateBytes ploc i []               = unexpectedEof       (InBytes i ploc)

validateString :: Loc -> Int -> [TermToken] -> Either String [TermToken]
validateString _    _ (TkBreak    : ts) = return ts
validateString ploc i (TkString _ : ts) = validateString ploc (i+1) ts
validateString ploc i (tok        : _)  = unexpectedToken tok (InString i ploc)
validateString ploc i []                = unexpectedEof       (InString i ploc)

validateListN :: Loc -> Int -> Int -> [TermToken] -> Either String [TermToken]
validateListN    _ i len ts | i == len = return ts
validateListN ploc i len ts = do
    ts' <- validateTerm (InListN i len ploc) ts
    validateListN ploc (i+1) len ts'

validateList :: Loc -> Int -> [TermToken] -> Either String [TermToken]
validateList _    _ (TkBreak : ts) = return ts
validateList ploc i ts = do
    ts' <- validateTerm (InList i ploc) ts
    validateList ploc (i+1) ts'

validateMapN :: Loc -> Int -> Int -> [TermToken] -> Either String [TermToken]
validateMapN    _ i len ts  | i == len = return ts
validateMapN ploc i len ts  = do
    ts'  <- validateTerm (InMapNKey i len ploc) ts
    ts'' <- validateTerm (InMapNVal i len ploc) ts'
    validateMapN ploc (i+1) len ts''

validateMap :: Loc -> Int -> [TermToken] -> Either String [TermToken]
validateMap _    _ (TkBreak : ts) = return ts
validateMap ploc i ts = do
    ts'  <- validateTerm (InMapKey i ploc) ts
    ts'' <- validateTerm (InMapVal i ploc) ts'
    validateMap ploc (i+1) ts''

--------------------------------------------------------------------------------
-- Utilities

maxInt, minInt, maxWord :: Num n => n
maxInt    = fromIntegral (maxBound :: Int)
minInt    = fromIntegral (minBound :: Int)
maxWord   = fromIntegral (maxBound :: Word)

maxInt8, minInt8, maxWord8 :: Num n => n
maxInt8    = fromIntegral (maxBound :: Int8)
minInt8    = fromIntegral (minBound :: Int8)
maxWord8   = fromIntegral (maxBound :: Word8)

maxInt16, minInt16, maxWord16 :: Num n => n
maxInt16    = fromIntegral (maxBound :: Int16)
minInt16    = fromIntegral (minBound :: Int16)
maxWord16   = fromIntegral (maxBound :: Word16)

maxInt32, minInt32, maxWord32 :: Num n => n
maxInt32    = fromIntegral (maxBound :: Int32)
minInt32    = fromIntegral (minBound :: Int32)
maxWord32   = fromIntegral (maxBound :: Word32)

-- | Do a careful check to ensure an @'Int'@ is in the
-- range of a @'Word32'@.
intIsValidWord32 :: Int -> Bool
intIsValidWord32 n = b1 && b2
  where
    -- NOTE: this first comparison must use Int for
    -- the check, not Word32, in case a negative value
    -- is given. Otherwise this check would fail due to
    -- overflow.
    b1 = n >= 0
    -- NOTE: we must convert n to Word32, otherwise,
    -- maxWord32 is inferred as Int, and because
    -- the maxBound of Word32 is greater than Int,
    -- it overflows and this check fails.
    b2 = (fromIntegral n :: Word32) <= maxWord32

unI# :: Int -> Int#
unI#   (I#   i#) = i#

unW# :: Word -> Word#
unW#   (W#  w#) = w#

unW8# :: Word8 -> Word#
unW8#  (W8# w#) = w#

unF# :: Float -> Float#
unF#   (F#   f#) = f#

unD# :: Double -> Double#
unD#   (D#   f#) = f#

#if defined(ARCH_32bit)
unW64# :: Word64 -> Word64#
unW64# (W64# w#) = w#

unI64# :: Int64 -> Int64#
unI64# (I64# i#) = i#
#endif
