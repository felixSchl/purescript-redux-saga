# purescript-redux-saga

Redux-saga inspired library for dealing with I/O in Purescript apps. The idea
is to completely isolate all I/O from pure code, meaning that neither the
reducer, nor the components, nor the action creators do _any_ kind of I/O
leaving the application mostly pure and placing all I/O into a single location.

To do so, purescript-redux-saga creates a virtual thread of execution whose
inputs are either actions produced by the UI or attached Sagas, or values
received through "channels".

# API Docs

API documentation is [published on Pursuit](http://pursuit.purescript.org/packages/purescript-redux-saga).

## Usage Example

``` purescript
-- Types.purs
type GlobalState = {}
data Action
  = LoginRequest { username :: String, password :: String }
  | LoginFailure Error
  | LoginSuccess { username :: String, token :: String }

-- Sagas.purs - Perform *all* I/O your app does here
saga :: ∀ env. Saga env Action GlobalState Unit
saga = forever do
  take case _ of
    LoginRequest { username, password } -> Just do
      liftAff (attempt $ authenticate username password) >>= case _ of
        Left err    -> put $ LoginFailure err
        Right token -> put $ LoginSuccess { username, token }
      _ -> Nothing

-- Store.purs - Install the Saga middleware
mkStore
  :: ∀ eff
   . Eff  (ReduxEffect _)
          (ReduxStore _ GlobalState Action)
mkStore = Redux.createStore reducer initialState middlewareEnhancer
  where
  initialState = {}
  middlewareEnhancer = Redux.applyMiddleware
    [ loggerMiddleware
    , sagaMiddleware saga
    ]

-- Main.purs - Tie the bow
main :: ∀ e. Eff _ Unit
main = do
  store <- mkStore
  Redux.createProviderElement store [ Redux.createElement_ appClass [] ]
```

For a fully worked example, have a look at [purescript-redux-saga-example](https://github.com/felixschl/purescript-redux-saga-example).
