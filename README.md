# dipper

watch and register service for etcd, zookeeper.

## register service
```erlang
Value = jiffy:encode(#{
    port => 11234,
    ip => <<"127.0.0.1">>
}),
dipper_service:register(server1, eetcd_driver,  #{ 
    ttl => 10,
    key => <<"grpc/auth/1.0/127.0.0.1">>,
    value => Value
}).
```

## watch service
```erlang
dipper_client:start_watch(watch1, eetcd_driver, #{
    key => "grpc/auth"
}).
```
## subscribe & unsubscribe

```erlang
%% subscribe
Ref = dipper:subscribe(watch1, fun ?MODULE:start/1).

%% unsubscribe
dipper:unsubscribe(Ref).
```

## get service
```erlang
%% get service
dipper:get_all_service(Watch1).
```
