# dipper

watch and register service for etcd, zookeeper.

## Quick Start
### 1. register & unregister
```erlang
%% register service
dipper_service:register(server1, eetcd_driver,  #{ 
    ttl => 10,
    key => <<"grpc/auth/1.0/127.0.0.1">>,
    value => <<"{\"port\":1123}">>,
    endpoints => [{"127.0.0.1", 2379}]
}).

%% unregister service
dipper_service:unregister(server1).
```

### 2. watch service
```erlang
%% start watch
dipper_watch:start(watch1, eetcd_driver, #{
    key => "grpc/auth",
    endpoints => [{"127.0.0.1", 2379}]
}).

%% get service
dipper:get_service(watch1).

%% stop watch
dipper_watch:stop(watch1).
```
## subscribe & unsubscribe

```erlang
%% subscribe
Ref = dipper:subscribe(watch1, fun ?MODULE:start/1).

%% unsubscribe
dipper:unsubscribe(Ref).
```
