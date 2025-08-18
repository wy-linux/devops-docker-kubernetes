### Docker 网络相关命令
```bash
# 创建自定义bridge网络
docker network create my-bridge-network --driver=bridge

# 创建带子网的bridge网络
docker network create --subnet=172.20.0.0/16 --driver=bridge --gateway=172.28.0.1 custom-network

# 列出所有网络
docker network ls

# 查看网络详细信息
docker network inspect my-bridge-network

# 删除指定网络
docker network rm my-bridge-network

# 删除所有未使用网络
docker network prune
```



### 四种Docker常见网络模式
1. Bridge 网络 
> Docker 默认创建的网络模式（名为 bridge）。每个容器通过虚拟网卡连接到 docker0 网桥（Linux）或虚拟交换机（Windows/macOS），并分配独立 IP。容器间通过 IP 或容器名（需自定义网络）通信，与宿主机隔离
```bash
# 创建自定义 bridge 网络
docker network create my-bridge

# 运行容器并加入该网络
docker run -d --name web --network my-bridge nginx
docker run -it --network my-bridge alpine ping web  # 直接通过容器名访问
```

2. Host 网络
> 容器共享宿主机的网络命名空间，直接使用宿主机 IP 和端口，不进行网络隔离
```bash
docker run -d --network host nginx  # 容器直接使用宿主机网络
# 访问方式：http://宿主机IP:80
```

3. None 网络
> 容器不配置任何网络栈，仅有 lo 环回接口（127.0.0.1），完全断网
```bash
docker run -it --network none alpine sh
ip addr  # 仅显示 lo 接口
```

4. Container 网络 (container:<name|id>)
> 新容器共享指定容器的网络命名空间，两者使用相同的 IP、端口和网络配置，容器间可通过 localhost 直接通信
```bash
docker run -d --name main-app nginx
docker run -it --network container:main-app alpine wget -qO- localhost  # 直接访问 main-app 的 80 端口
```