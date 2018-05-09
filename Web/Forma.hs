-- |
-- Module      :  Web.Forma
-- Copyright   :  © 2017–2018 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- This module provides a tool for validation of forms that are represented
-- in the JSON format. Sending forms in JSON format via an AJAX request
-- instead of traditional submitting of forms has a number of advantages:
--
--     * Smoother user experience: no need to reload the whole page.
--     * Form rendering is separated and lives only in GET handler, POST (or
--       whatever method you deem appropriate for your use case) handler
--       only handles validation and actual effects that form submission
--       should initiate.
--     * You get a chance to organize form input just like you want.
--
-- The task of validation of a form in the JSON format may seem simple, but
-- it's not trivial to get it right. The library allows you to:
--
--     * Define form parser using type-safe applicative notation with field
--       labels being stored on the type label which excludes any
--       possibility of typos and will force all your field labels be always
--       up to date.
--     * Parse JSON 'Value' according to the definition of form you created.
--     * Stop parsing immediately if given form is malformed and cannot be
--       processed.
--     * Validate forms using any number of /composable/ checkers that you
--       write for your specific problem domain. Once you have a vocabulary
--       of checkers, creation of new forms is just a matter of combining
--       them, and yes they do combine nicely.
--     * Collect validation errors from multiple branches of parsing (one
--       branch per form field) in parallel, so validation errors in one
--       branch do not prevent us from collecting validation errors from
--       other branches. This allows for a better user experience as the
--       user can see all validation errors at the same time.
--     * Use 'optional' and @('<|>')@ from "Control.Applicative" in your
--       form definitions instead of ugly ad-hoc stuff (yes
--       @digestive-functors@, I'm looking at you).
--     * When individual validation of fields is done, you get a chance to
--       perform some actions and either decide that form submission has
--       succeeded, or indeed perform additional checks that may depend on
--       several form fields at once and signal a validation error assigned
--       to a specific field(s). This constitute the “second level” of
--       validation, so to speak.
--
-- __This library requires at least GHC 8 to work.__
--
-- You need to enable at least @DataKinds@ and @TypeApplications@ language
-- extensions to use this library.

{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE ExplicitForAll       #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

module Web.Forma
  ( -- * Constructing a form
    field
  , field'
  , value
  , subParser
  , withCheck
    -- * Running a form
  , runForm
  , pick
  , mkFieldError
    -- * Helpers
  , toResponse
  , showFieldPath
    -- * Types and type functions
  , FormResult (..)
  , FormParser
  , ValidationResult (..)
  , SelectedName(..)
  , InSet
  , FieldError(..) )
where

import Control.Applicative
import Control.Monad.Except
import Data.Aeson
import Data.Default.Class
import Data.Kind
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Proxy
import Data.Semigroup (Semigroup (..))
import Data.String (fromString)
import Data.Text (Text)
import GHC.TypeLits
import qualified Data.Aeson.Types    as A
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty  as NE
import qualified Data.Map.Strict     as M
import qualified Data.Text           as T

----------------------------------------------------------------------------
-- Types

-- | State of a parsing branch.

data FormResult (names :: [Symbol]) a
  = FormParseError [SelectedName names] Text
    -- ^ Parsing of JSON failed, this is fatal, we shut down and report the
    -- parsing error. The first component specifies path to a problematic
    -- field and the second component is the text of error message.
  | FormValidationError (FieldError names)
    -- ^ Validation of a field failed. This is also fatal but we still try
    -- to validate other branches (fields) to collect as many validation
    -- errors as possible.
  | FormSuccess a
    -- ^ Success, we've got a result to return.
  deriving (Eq, Functor, Show)

instance Applicative (FormResult names) where
  pure                                            = FormSuccess
  (FormParseError l msg) <*> _                     = FormParseError l msg
  (FormValidationError _)  <*> (FormParseError l msg) = FormParseError l msg
  (FormValidationError e0) <*> (FormValidationError e1) = FormValidationError (e0 <> e1)
  (FormValidationError e)  <*> FormSuccess _           = FormValidationError e
  FormSuccess _           <*> (FormParseError l msg) = FormParseError l msg
  FormSuccess _           <*> (FormValidationError e)  = FormValidationError e
  FormSuccess f           <*> FormSuccess x           = FormSuccess (f x)

-- | The type represents the parser that you can run on a 'Value' with the
-- help of 'runForm'. The only way for the user of the library to create a
-- parser is via the 'field' function. Users can combine existing parsers
-- using the applicative notation.
--
-- 'FormParser' is parametrized by three type variables:
--
--     * @names@—collection of field names we can use in a form to be parsed
--       with this parser.
--     * @m@—underlying monad, 'FormParser' is not a monad itself, so it's
--       not a monad transformer, but validation can make use of the @m@
--       monad.
--     * @a@—result of parsing.
--
-- 'FormParser' is not a monad because it's not possible to write a 'Monad'
-- instance with the properties that we want (validation errors should not
-- lead to short-cutting behavior).

newtype FormParser (names :: [Symbol]) m a = FormParser
  { unFormParser
      :: Value
      -> ([SelectedName names] -> [SelectedName names])
      -> m (FormResult names a)
  }

instance Functor m => Functor (FormParser names m) where
  fmap f (FormParser x) = FormParser $ \v path ->
    fmap (fmap f) (x v path)

instance Applicative m => Applicative (FormParser names m) where
  pure x = FormParser $ \_ _ ->
    pure (FormSuccess x)
  (FormParser f) <*> (FormParser x) = FormParser $ \v path ->
    pure (<*>) <*> f v path <*> x v path

instance Applicative m => Alternative (FormParser names m) where
  empty = FormParser $ \_ path ->
    pure (FormParseError (path []) "empty")
  (FormParser x) <|> (FormParser y) = FormParser $ \v path ->
    let g x' y' =
          case x' of
            FormParseError    _ _ -> y'
            FormValidationError _ -> x'
            FormSuccess         _ -> x'
    in pure g <*> x v path <*> y v path

-- | This is a type that user must return in the callback passed to the
-- 'runForm' function. Quite simply, it allows you either report a error or
-- finish successfully.

data ValidationResult (names :: [Symbol]) a
  = ValidationError (FieldError names)
    -- ^ Form submission failed, here are the validation errors.
  | ValidationSuccess a
    -- ^ Form submission succeeded, send this info.
  deriving (Eq, Show)

-- | @'SelectedName' names@ represents a name ('Text' value) that is
-- guaranteed to be in the @names@, which is a set of strings on type level.
-- The purpose if this type is to avoid typos and to force users to update
-- field names everywhere when they decide to change them. The only way to
-- obtain a value of type 'SelectedName' is via the 'pick' function, which
-- see.

newtype SelectedName (names :: [Symbol]) = SelectedName
  { unSelectedName :: Text
  }
  deriving (Eq, Ord, Show)

-- | The type function computes a 'Constraint' which is satisfied when its
-- first argument is contained in its second argument. Otherwise a friendly
-- type error is displayed.

type family InSet (n :: Symbol) (ns :: [Symbol]) :: Constraint where
  InSet n '[]    = TypeError
    ('Text "The name " ':<>: 'ShowType n ':<>: 'Text " is not in the given set."
     ':$$:
     'Text "Either it's a typo or you need to add it to the set first.")
  InSet n (n:ns) = ()
  InSet n (m:ns) = InSet n ns

-- | Pick a name from a given collection of names.
--
-- Typical usage:
--
-- > type Fields = '["foo", "bar", "baz"]
-- >
-- > myName :: SelectedName Fields
-- > myName = pick @"foo" @Fields
--
-- It's a good idea to use 'pick' to get field names not only where this
-- approach is imposed by the library, but everywhere you need to use the
-- field names, in your templates for example.

pick :: forall (name :: Symbol) (names :: [Symbol]).
  ( KnownSymbol name
  , InSet name names )
  => SelectedName names
pick = (SelectedName . T.pack . symbolVal) (Proxy :: Proxy name)

-- | Parse error. Non-public helper type.

data ParseError (names :: [Symbol])
  = ParseError [SelectedName names] Text
  deriving (Eq, Show)

instance ToJSON (ParseError names) where
  toJSON (ParseError path msg) = object
    [ "field"   .= showFieldPath path
    , "message" .= msg
    ]

-- | Error info in JSON format associated with a particular form field.
-- Parametrized by @names@, which is a collection of field names (on type
-- level) the target field belongs to. 'FieldError' is an instance of
-- 'Semigroup' and that's how you combine values of that type. Note that
-- it's not a 'Monoid', because we do not want to allow empty 'FieldError's.

newtype FieldError (names :: [Symbol])
  = FieldError (Map (NonEmpty (SelectedName names)) Value)
  deriving (Eq, Show)

instance Semigroup (FieldError names) where
  (FieldError x) <> (FieldError y) = FieldError (M.union x y)

instance ToJSON (FieldError names) where
  toJSON (FieldError m) = (object . fmap f . M.toAscList) m
    where
      f (path, err) = showFieldPath (NE.toList path) .= err

-- | This is a smart constructor for the 'FieldError' type, and the only way
-- to obtain values of that type.
--
-- Typical usage:
--
-- > type Fields = '["foo", "bar", "baz"]
-- >
-- > myError :: FieldError Fields
-- > myError = mkFieldError (pick @"foo" @Fields) "That's all wrong."
--
-- See also: 'pick' (to create 'SelectedName').
--
-- __Note__: type of the first argument has been changed in the version
-- /1.0.0/.

mkFieldError :: ToJSON e
  => NonEmpty (SelectedName names) -- ^ The path to problematic field
  -> e                 -- ^ Data that represents error
  -> FieldError names
mkFieldError path x =
  FieldError (M.singleton path (toJSON x))

-- | An internal type of response that we covert to 'Value' before returning
-- it.

data Response (names :: [Symbol]) = Response
  { responseParseError :: Maybe (ParseError names)
  , responseFieldError :: Maybe (FieldError names)
  , responseResult     :: Value }

instance Default (Response names) where
  def = Response
    { responseParseError = Nothing
    , responseFieldError = Nothing
    , responseResult     = Null }

instance ToJSON (Response names) where
  toJSON Response {..} = object
    [ "parse_error"  .= responseParseError
    , "field_errors" .= maybe (Object HM.empty) toJSON responseFieldError
    , "result"       .= responseResult ]

----------------------------------------------------------------------------
-- Constructing a form

-- | Construct a parser for a field. Combine multiple 'field's using
-- applicative syntax like so:
--
-- > type LoginFields = '["username", "password", "remember_me"]
-- >
-- > data LoginForm = LoginForm
-- >   { loginUsername   :: Text
-- >   , loginPassword   :: Text
-- >   , loginRememberMe :: Bool
-- >   }
-- >
-- > loginForm :: Monad m => FormParser LoginFields m LoginForm
-- > loginForm = LoginForm
-- >   <$> field @"username" notEmpty
-- >   <*> field @"password" notEmpty
-- >   <*> field' @"remember_me"
-- >
-- > notEmpty :: Monad m => Text -> ExceptT Text m Text
-- > notEmpty txt =
-- >   if T.null txt
-- >     then throwError "This field cannot be empty"
-- >     else return txt
--
-- Referring to the types in the function's signature, @s@ is extracted from
-- JSON 'Value' for you automatically using its 'FromJSON' instance. The
-- field value is taken in assumption that top level 'Value' is a
-- dictionary, and field name is a key in that dictionary. So for example a
-- valid JSON input for the form shown above could be this:
--
-- > {
-- >   "username": "Bob",
-- >   "password": "123",
-- >   "remember_me": true
-- > }
--
-- Once value of type @s@ is extracted, validation phase beings. The
-- supplied checker (you can easy compose them with @('>=>')@, as they are
-- Kleisli arrows) is applied to the @s@ value and validation either
-- succeeds producing an @a@ value, or we collect an error in the form of a
-- value of @e@ type, which is fed into 'mkFieldError' internally.
--
-- To run a form composed from 'field's, see 'runForm'.

field :: forall (name :: Symbol) (names :: [Symbol]) m e s a.
  ( KnownSymbol name
  , InSet name names
  , Monad m
  , ToJSON e
  , FromJSON s )
  => (s -> ExceptT e m a)
     -- ^ Checker that performs validation and possibly transformation of
     -- the field value
  -> FormParser names m a
field check = withCheck @name check (field' @name)

-- | The same as 'field', but does not require a checker.

field' :: forall (name :: Symbol) (names :: [Symbol]) m a.
  ( KnownSymbol name
  , InSet name names
  , Monad m
  , FromJSON a )
  => FormParser names m a
field' = subParser @name value

-- | Interpret the current field as a value of type @a@.
--
-- @since 1.0.0

value :: (Monad m , FromJSON a) => FormParser names m a
value = FormParser $ \v path ->
  case A.parseEither parseJSON v of
    Left msg -> do
      let msg' = drop 2 (dropWhile (/= ':') msg)
      return (FormParseError (path []) $ fromString msg')
    Right x -> return (FormSuccess x)

-- | Use a given parser to parse a field. Suppose that you have a parser
-- @loginForm@ that parses a structure like this one:
--
-- > {
-- >   "username": "Bob",
-- >   "password": "123",
-- >   "remember_me": true
-- > }
--
-- Then @subParser \@"login" loginForm@ will parse this:
--
-- > {
-- >   "login": {
-- >      "username": "Bob",
-- >      "password": "123",
-- >      "remember_me": true
-- >    }
-- > }
--
-- @since 1.0.0

subParser :: forall (name :: Symbol) (names :: [Symbol]) m a.
  ( KnownSymbol name
  , InSet name names
  , Monad m )
  => FormParser names m a -- ^ Subparser
  -> FormParser names m a -- ^ Wrapped parser
subParser p = FormParser $ \v path -> do
  let name = pick @name @names
      f = withObject "form field" (.: unSelectedName name)
      path' = path . (name :)
  case A.parseEither f v of
    Left msg -> do
      let msg' = drop 2 (dropWhile (/= ':') msg)
      return (FormParseError (path' []) $ fromString msg')
    Right v' ->
      unFormParser p v' path'

-- | Transform a form by applying a checker on its result.
--
-- > passwordsMatch (a, b) = do
-- >   if a == b
-- >     then return a
-- >     else throwError "Passwords don't match!"
-- >
-- > createNewPasswordForm =
-- >   withCheck @"password_confirmation" passwordsMatch
-- >     ((,) <$> field @"password" notEmpty
-- >          <*> field @"password_confirmation" notEmpty)
--
-- Note that you must specify the field name on which to add a validation
-- error message in case the check fails.
--
-- @since 0.2.0

withCheck :: forall (name :: Symbol) (names :: [Symbol]) m e s a.
  ( KnownSymbol name
  , InSet name names
  , Monad m
  , ToJSON e )
  => (s -> ExceptT e m a) -- ^ The check to perform
  -> FormParser names m s -- ^ Original parser
  -> FormParser names m a -- ^ Parser with the check attached
withCheck check (FormParser f) = FormParser $ \v path -> do
  let name = pick @name @names
  r <- f v path
  case r of
    FormSuccess x -> do
      res <- runExceptT (check x)
      return $ case res of
        Left verr ->
          let path' = NE.fromList (path . (name :) $ [])
          in FormValidationError (mkFieldError path' verr)
        Right y ->
          FormSuccess y
    FormValidationError e ->
      return (FormValidationError e)
    FormParseError path' msg ->
      return (FormParseError path' msg)

----------------------------------------------------------------------------
-- Running a form

-- | Run the supplied parser on given input and call the specified callback
-- that uses the result of parsing on success.
--
-- The callback can either report an error with 'ValidationError', or report
-- success providing a value in 'ValidationSuccess'.

runForm :: (Monad m)
  => FormParser names m a -- ^ The form parser to run
  -> Value             -- ^ Input for the parser
  -> (a -> m (ValidationResult names b)) -- ^ Callback that is called on success
  -> m (FormResult names b)          -- ^ The result
runForm (FormParser p) v f = do
  r <- p v id
  case r of
    FormSuccess x -> do
      r' <- f x
      return $ case r' of
        ValidationError validationError ->
          FormValidationError validationError
        ValidationSuccess result ->
          FormSuccess result
    FormValidationError validationError ->
      return $ FormValidationError validationError
    FormParseError path msg ->
      return $ FormParseError path msg

----------------------------------------------------------------------------
-- Helpers

-- | Convert 'FormResult' to 'Response'.
--
-- 'Response' converted with `toJSON` to 'Value' has the following format:
--
-- > {
-- >   "parse_error": "Text or null."
-- >   "field_errors":
-- >     {
-- >       "foo": "Foo's error serialized to JSON.",
-- >       "bar": "Bar's error…"
-- >     }
-- >   "result": "What you return from the callback in ValidationSuccess."
-- > }

toResponse :: (ToJSON a)
  => FormResult names a
  -> Response names
toResponse r =
  case r of
    FormSuccess result ->
      def { responseResult = toJSON result }
    FormValidationError validationError ->
      def { responseFieldError = pure validationError }
    FormParseError path msg ->
      def { responseParseError = Just (ParseError path msg) }

-- | Produce textual representation of path to a field.

showFieldPath :: [SelectedName names] -> Text
showFieldPath = T.intercalate "." . fmap unSelectedName
