# dipper

集成进程池，gen_rpc, grpc的服务发现与注册的插件, 可使用etcd,redis,ZooKeeper等第三方服务。

## 注册服务
```erlang
register_gen_rpc_service(Port) ->
    Opts = [{service, {?MODULE, start_rpc, [Port]}}],
    Name = test_web,
    Key = <<"gen_rpc">>,
    dipper_service:register(Name, Key, jsx:encode(#{ port => Port }), Opts).
```
如果当前节点为test@127.0.0.1 则上面最终会注册到key: gen_rpc/test_web/test@127.0.0.1

## watch服务

如果注册服务以grpc,gen_rpc2,gen_rpc开头，以${node}结尾时，则按下表启动相应的客户端

|key|参数|描述|
|:---|:---|:---|
|grpc/.../${Node}|host,port,decoder,size,auto_reconnect|自动启动grpc客户端|
|gen_rpc2/.../${Node}|port,size,auto_reconnect|自动启动能够双向通信的gen_rpc客户端|
|gen_rpc/.../${Node}|port,size,auto_reconnect|启动gen_rpc客户端|

参数说明

|参数名|类型|说明|
|:---|:---|:---|
|host|binary|必需|
|size|int|非必需，进程池大小，默认：1|
|auto_reconnect|int|非必需，重连时间，默认：10秒|


```erlang
start() ->
    dipper_client:watch(web_agent, <<"gen_rpc">>, {?MODULE, handle_watch_data, []}).

handle_watch_data(Name, Type, Kv) ->
    io:format("handle_watch_data ~p,~p,~p", [Name, Type, Kv]).
```

## checkout出服务

```erlang
call(Name, Mod, Fun, Args) ->
    case dipper_client:checkout(Name) of
        undefined ->
            not_found;
        #{node := Node} ->
            Pool = ?POOL(Name, Node),
            erpc_client:gen_rpc_call(Pool, Mod, Fun, Args)
    end.

test() ->
    call(web_agent, io_lib, format, ["~p~n", [zwx]]).
```

## 其它watch的服务
watch其它服务时，请在watch时传进去的参数里面自己做处理，可以参考gen_rpc的处理。
