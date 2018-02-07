# purescript-redux-saga

Redux-saga inspired library for dealing with I/O in Purescript apps. The idea
is to completely isolate all I/O from pure code, meaning that neither the
reducer, nor the components, nor the action creators do _any_ kind of I/O
leaving the application mostly pure and placing all I/O into a single location.

To do so, purescript-redux-saga creates a virtual thread of execution whose
inputs are either actions produced by the UI or attached Sagas, or values
received through "channels".

## Usage Example

```haskell
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

## The Saga Monad

The `Saga` monad is an opinionated, closed monad with a range of functionality.


```haskell
--             read-only environment, accessible via `MonadAsk` instance
--             /   your state container type (reducer)
--             |    /    the type this saga consumes (i.e. actions)
--             |    |     /    the type of output this saga produces (i.e. actions)
--             |    |     |     /    the return value of this Saga
--             |    |     |     |     /
newtype Saga' env state input output a = ...
```

### The `env` parameter

The `env` parameter gives us access to a read-only environment, accessible via
`MonadAsk` instance. Forked computations have the opportunity to change this
environment for the execution of the fork without affecting the current thread's
`env`.

```haskell
type MyConfig = { apiUrl :: String }

logApiUrl :: ∀ state input output. Saga' MyConfig state input output Unit
logApiUrl = void do
    { apiUrl } <- ask
    liftIO $ Console.log apiUrl
```

### The `state` parameter

The `state` parameter gives us read access to the current application state via
the `select` combinator. This value may change over time.

```haskell
type MyState = { currentUser :: String }

logUser :: ∀ env input output. Saga' env MyState input output Unit
logUser = void do
    { currentUser } <- select
    liftIO $ Console.log currentUser
```

### The `input` parameter

The `input` parameter denotes the type of input this saga consumes. This in
combination with the `output` parameter exposes sagas for what they naturally
are: pipes consuming `input` and producing `output`. Typically this input type
would correspond to your application's actions type.

```haskell
data MyAction
  = LoginRequest Username Password
  | LogoutRequest

loginFlow :: ∀ env state output. Saga' env state MyAction MyAction Unit
loginFlow = forever do
  take case _ of
    LoginRequest user pw -> do
      ...
    _ -> Nothing -- ignore other actions
```

### The `output` parameter

The `output` parameter denotes the type of output this saga produces. Typically
this input type would correspond to your application's actions type. The
`output` sagas produce is fed back into redux cycle by dispatching it to the
store.

```haskell
data MyAction
  = LoginRequest Username Password
  | LogoutSuccess Username
  | LogoutFailure Error
  | LogoutRequest

loginFlow :: ∀ env state. Saga' env state MyAction MyAction Unit
loginFlow = forever do
  take case _ of
    LoginRequest user pw -> do
      liftAff (attempt {- some I/O -}) >>= case _ of
        Left err -> put $ LoginFailure err
        Right v  -> put $ LoginSuccess user
    _ -> Nothing -- ignore other actions
```

### The `a` parameter

The `a` parameter allows every saga to return a value, making it composable.
Here's an example of a contrived combinator

```haskell
type MyAppConf = { apiUrl :: String }
type Account = { id :: String, email :: String }

getAccount
  :: ∀ state input output
    . String
  -> Saga' MyAppConf state input output Account
getAccount id = do
  { apiUrl } <- ask
  liftAff (API.getAccounts apiUrl)

-- later ...

saga
  :: ∀ state input output
   . Saga' MyAppConf state input output Unit
saga = do
  account <- getAccount "123-dfa-123"
  liftEff $ Console.log $ show account.email
```

## The core combinators

## `take` - Pull an `input` and maybe handle it

`take` blocks to receive an input value for which the given function returns
`Just` a saga to execute. This saga is then executed on the same thread,
blocking until it finished running.

```haskell
data Action = SayFoo | SayBar

sayOnlyBar
  :: ∀ env state Action Action
   . Saga' env state Action Action Unit
sayOnlyBar = do
  take case _ of
    SayFoo -> Nothing
    SayBar -> Just do
      liftEff $ Console.log "Bar!"
```

## `put` - Emit an `output`

`put` emits an `output` which gets dispatched to your redux store and in turn
becomes available to sagas.

```haskell
data Action = SayFoo | SayBar

sayOnlyBar
  :: ∀ env state
   . Saga' env state Action Action Unit
sayOnlyBar = do
  put SayBar -- trigger a `SayBar` action right away.
  take case _ of
    SayFoo -> Nothing
    SayBar -> Just do
      liftEff $ Console.log "Bar!"

-- >> Bar!
```

## `select` - Access the current redux state

`select` gives us access the the current application state and it's output
varies over time as the application state changes.

```haskell
printState
  :: ∀ env state input output
  => Show state
   . Saga' env state input output Unit
printState = do
  state <- select
  liftAff $ Console.log $ show state
```

## `fork` - Create non-blocking sub-sagas

`fork` allows us to put a saga in the background, so that other processing can
continue to occur:

```haskell
helloWorld
  :: ∀ env state input output
   . Saga' env state input output Unit
helloWorld = do
  fork $ do
    liftAff $ delay $ 10000.0 # Milliseconds
    liftAff $ Console.log "World!"
  liftEff $ Console.log "Hello"

-- >> Hello
-- >> World!
```

`fork` returns a `SagaTask a`, which can later be joined using `joinTask` or
canceled using `cancelTask`.

**important**: A saga thread won't finish running until all attached forks have
finished running!

## `forkNamed`

`forkNamed` is a variant of `fork` that allows us to give the fork a name, which
comes in very handy for error reporting.

```haskell
helloWorld'
  :: ∀ env state input output
   . Saga' env state input output Unit
helloWorld' = do
  forkNamed "wait for world" $ do
    liftAff $ delay $ 100.0 # Milliseconds
    liftAff $ throwError $ error "BOOM"
  liftEff $ Console.log "Hello"

-- >> Hello
-- Error: Saga terminated due to error, stack trace follows:
-- Error: Process (root>main - thread, pid=0) terminated due to error, stack trace follows:
-- Error: Process (root>main>wait for world - thread, pid=2) terminated due to error, stack trace follows:
-- Error: Process (root>main>wait for world - task, pid=3) terminated due to error, stack trace follows:
-- Error: BOOM
--     at Object.exports.error (/home/felix/projects/purescript-redux-saga/output/Control.Monad.Eff.Exception/foreign.js:8:10)
--     at /home/felix/projects/purescript-redux-saga/output/Test.Main/index.js:83:171
--     at go (/home/felix/projects/purescript-redux-saga/output/Pipes.Internal/index.js:295:28)
--     at /home/felix/projects/purescript-redux-saga/output/Pipes.Internal/index.js:291:83
```

## `joinTask` - Join a fork

`joinTask` allows us to block until a given `SagaTask` returns.

```haskell
helloWorld
  :: ∀ env state input output
   . Saga' env state input output Unit
helloWorld = do
  task <- fork $ do
    liftAff $ delay $ 10000.0 # Milliseconds
    liftAff $ Console.log "World!"
  joinTask task
  liftEff $ Console.log "Hello"

-- >> World!
-- >> Hello
```

## `cancelTask` - Cancel a fork

`cancelTask` allows us to cancel a given `SagaTask`.

```haskell
helloWorld
  :: ∀ env state input output
   . Saga' env state input output Unit
helloWorld = do
  task <- fork $ do
    liftAff $ delay $ 10000.0 # Milliseconds
    liftAff $ Console.log "World!"
  cancelTask task
  liftEff $ Console.log "Hello"

-- >> Hello
```

## `channel` - Inject arbitrary values from I/O

`channel` allows us to inject any number of arbitrary values from the outside
world into the current saga and any attached sub-sagas. The first argument to
this function is the `emit` callback, that when invoked will inject the provided
value into the current saga's thread.

```haskell
foreign import data Websocket :: Type

onWsMessage
  :: ∀ eff. Websocket
  -> (WSMessage -> Eff eff Unit)
  -> Eff eff Unit

data MyAction

data WSMessage
  = WsMessageFoo
  | WsMessageFoo

myWebsocket
  :: ∀ env state MyAction MyAction output
   . Websocket
  -> Saga' env state input output Unit
myWebsocket ws = do
  channel
    (\emit -> onWsMessage emit ws)
    do
      -- notice we have to `Left` and `Right` pattern match.
      -- `Left` patterns are `input` values from the saga the channel was
      -- created in and `Right` patterns are values emitted from the channel.
      take (Right WsMessageFoo) -> Just do
        liftAff $ Console.log "Foo from the Websocket"
      take (Right WsMessageBar) -> Just do
        liftAff $ Console.log "Bar from the Websocket"
      take (Left MyAction) -> Just do
        liftAff $ Console.log "Action from the outer saga"
```

## `localEnv` - Run a saga with a modify environment


```haskell
printEnv
  :: ∀ env state input output
  => Show env
   . Saga' env state input output Unit
printEnv = do
  env <- ask
  liftEff $ Console.log $ show env

saga
  :: ∀ env state input output
   . Saga' env state input output Unit
saga = do
  localEnv (const "Hello") printEnv
  localEnv (const "World!") printEnv

-- >> Hello
-- >> World!
```
