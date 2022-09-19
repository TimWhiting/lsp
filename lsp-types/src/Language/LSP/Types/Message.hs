{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE DuplicateRecordFields  #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeInType             #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}

module Language.LSP.Types.Message where

import           Language.LSP.Types.Common
import           Language.LSP.Types.Internal.Generated
import           Language.LSP.Types.Internal.Lenses
import           Language.LSP.Types.LspId
import           Language.LSP.Types.Method             ()
import           Language.LSP.Types.Utils

import           Control.Lens.TH
import           Data.Aeson                            hiding (Null)
import qualified Data.Aeson                            as J
import           Data.Aeson.TH
import           Data.Kind
import           Data.String                           (IsString (..))
import           Data.Text                             (Text)
import           GHC.Generics
import           GHC.TypeLits                          (KnownSymbol)

-- 'RequestMessage', 'ResponseMessage', 'ResponseError', and 'NotificationMessage'
-- aren't present in the metamodel, although they should be.
-- https://github.com/microsoft/vscode-languageserver-node/issues/1079

-- | Notification message type as defined in the spec.
data NotificationMessage =
  NotificationMessage
    { _jsonrpc :: Text
    , _method  :: Text
    , _params  :: Maybe Value
    } deriving (Show, Eq, Generic)

deriveJSON lspOptions ''NotificationMessage

-- This isn't present in the metamodel.
-- | Request message type as defined in the spec.
data RequestMessage = RequestMessage
    { _jsonrpc :: Text
    , _id      :: Int32 |? Text
    , _method  :: Text
    , _params  :: Maybe Value
    } deriving (Show, Eq, Generic)

deriveJSON lspOptions ''RequestMessage

-- | Response error type as defined in the spec.
data ResponseError =
  ResponseError
    { _code    :: ErrorCodes
    , _message :: Text
    , _xdata   :: Maybe Value
    } deriving (Show, Eq, Generic)

deriveJSON lspOptions ''ResponseError

-- | Response message type as defined in the spec.
data ResponseMessage =
  ResponseMessage
    { _jsonrpc :: Text
    , _id      :: Int32 |? Text |? Null
    , _result  :: Maybe Value
    , _error   :: Maybe ResponseError
    } deriving (Show, Eq, Generic)

deriveJSON lspOptions ''ResponseMessage

-----
-- | Typed notification message, containing the correct parameter payload.
data TNotificationMessage (m :: Method f Notification) =
  TNotificationMessage
    { _jsonrpc :: Text
    , _method  :: SMethod m
    , _params  :: MessageParams m
    } deriving Generic

deriving instance Eq   (MessageParams m) => Eq (TNotificationMessage m)
deriving instance Show (MessageParams m) => Show (TNotificationMessage m)

instance (FromJSON (MessageParams m), FromJSON (SMethod m)) => FromJSON (TNotificationMessage m) where
  parseJSON = genericParseJSON lspOptions
instance (ToJSON (MessageParams m)) => ToJSON (TNotificationMessage m) where
  toJSON     = genericToJSON lspOptions
  toEncoding = genericToEncoding lspOptions

-- | Typed request message, containing hte correct parameter payload.
data TRequestMessage (m :: Method f Request) = TRequestMessage
    { _jsonrpc :: Text
    , _id      :: LspId m
    , _method  :: SMethod m
    , _params  :: MessageParams m
    } deriving Generic

deriving instance Eq   (MessageParams m) => Eq (TRequestMessage m)
deriving instance Show (MessageParams m) => Show (TRequestMessage m)

instance (FromJSON (MessageParams m), FromJSON (SMethod m)) => FromJSON (TRequestMessage m) where
  parseJSON = genericParseJSON lspOptions . addNullField "params"
instance (ToJSON (MessageParams m)) => ToJSON (TRequestMessage m) where
  toJSON     = genericToJSON lspOptions
  toEncoding = genericToEncoding lspOptions

data TResponseError (m :: Method f Request) =
  TResponseError
    { _code    :: ErrorCodes
    , _message :: Text
    , _xdata   :: Maybe (ErrorData m)
    } deriving Generic

deriving instance Eq   (ErrorData m) => Eq (TResponseError m)
deriving instance Show (ErrorData m) => Show (TResponseError m)

instance (FromJSON (ErrorData m)) => FromJSON (TResponseError m) where
  parseJSON = genericParseJSON lspOptions
instance (ToJSON (ErrorData m)) => ToJSON (TResponseError m) where
  toJSON     = genericToJSON lspOptions
  toEncoding = genericToEncoding lspOptions

-- TODO: similar functions for the others?
toUntypedResponseError :: (ToJSON (ErrorData m)) => TResponseError m -> ResponseError
toUntypedResponseError (TResponseError c m d) = ResponseError c m (fmap toJSON d)

-- | A typed response message with a correct result payload.
data TResponseMessage (m :: Method f Request) =
  TResponseMessage
    { _jsonrpc :: Text
    , _id      :: Maybe (LspId m)
    , _result  :: Either (TResponseError m) (MessageResult m)
    } deriving Generic

deriving instance (Eq   (MessageResult m), Eq (ErrorData m)) => Eq (TResponseMessage m)
deriving instance (Show (MessageResult m), Show (ErrorData m)) => Show (TResponseMessage m)

instance (ToJSON (MessageResult m), ToJSON (ErrorData m)) => ToJSON (TResponseMessage m) where
  toJSON TResponseMessage { _jsonrpc = jsonrpc, _id = lspid, _result = result }
    = object
      [ "jsonrpc" .= jsonrpc
      , "id" .= lspid
      , case result of
        Left  err -> "error" .= err
        Right a   -> "result" .= a
      ]

instance (FromJSON (MessageResult a), FromJSON (ErrorData a)) => FromJSON (TResponseMessage a) where
  parseJSON = withObject "Response" $ \o -> do
    _jsonrpc <- o .: "jsonrpc"
    _id      <- o .: "id"
    -- It is important to use .:! so that "result = null" (without error) gets decoded as Just Null
    _result  <- o .:! "result"
    _error   <- o .:? "error"
    result   <- case (_error, _result) of
      (Just err, Nothing) -> pure $ Left err
      (Nothing, Just res) -> pure $ Right res
      (Just _err, Just _res) -> fail $ "both error and result cannot be present: " ++ show o
      (Nothing, Nothing) -> fail "both error and result cannot be Nothing"
    return $ TResponseMessage _jsonrpc _id result

-- | A typed custom message. A special data type is needed to distinguish between
-- notifications and requests, since a CustomMethod can be both!
data TCustomMessage s f t where
  ReqMess :: TRequestMessage (Method_CustomMethod s :: Method f Request) -> TCustomMessage s f Request
  NotMess :: TNotificationMessage (Method_CustomMethod s :: Method f Notification) -> TCustomMessage s f Notification

deriving instance Show (TCustomMessage s f t)

instance ToJSON (TCustomMessage s f t) where
  toJSON (ReqMess a) = toJSON a
  toJSON (NotMess a) = toJSON a

instance KnownSymbol s => FromJSON (TCustomMessage s f Request) where
  parseJSON v = ReqMess <$> parseJSON v
instance KnownSymbol s => FromJSON (TCustomMessage s f Notification) where
  parseJSON v = NotMess <$> parseJSON v


-- ---------------------------------------------------------------------
-- Helper Type Families
-- ---------------------------------------------------------------------

-- | Map a method to the Request/Notification type with the correct
-- payload.
type family TMessage (m :: Method f t) :: Type where
  TMessage (Method_CustomMethod s :: Method f t) = TCustomMessage s f t
  TMessage (m :: Method f Request) = TRequestMessage m
  TMessage (m :: Method f Notification) = TNotificationMessage m

-- Some helpful type synonyms
type TClientMessage (m :: Method ClientToServer t) = TMessage m
type TServerMessage (m :: Method ServerToClient t) = TMessage m

-- | Replace a missing field in an object with a null field, to simplify parsing
-- This is a hack to allow other types than Maybe to work like Maybe in allowing the field to be missing.
-- See also this issue: https://github.com/haskell/aeson/issues/646
addNullField :: String -> Value -> Value
addNullField s (Object o) = Object $ o <> fromString s .= J.Null
addNullField _ v          = v

makeFieldsNoPrefix ''RequestMessage
makeFieldsNoPrefix ''ResponseMessage
makeFieldsNoPrefix ''NotificationMessage
makeFieldsNoPrefix ''ResponseError
makeFieldsNoPrefix ''TRequestMessage
makeFieldsNoPrefix ''TResponseMessage
makeFieldsNoPrefix ''TNotificationMessage
makeFieldsNoPrefix ''TResponseError
