### Docker 常用命令
```bash
# 镜像相关
docker images # 查看本地镜像  -a 列出所有镜像（包含中间层镜像）  -q 只显示镜像ID
docker search 镜像名称 # 远程仓库搜索镜像  --limit N 只列出N个镜像
docker pull 镜像名称:tag # 远程仓库拉去镜像，不指定tag默认latest
docker rmi -f 镜像ID # 删除镜像  
docker rmi -f $(docker images -qa) # 删除本地全部镜像



# 容器相关
docker run -it 镜像 /bin/bash # 前台交互式启动容器  退出方式：1.exit退出，容器停止 2.ctrl+p+q退出，容器不停止
docker run -d 镜像 # 后台启动容器 
docker run -it -p 宿主机端口:容器内端口 镜像 # 将宿主机指定端口映射到容器内指定端口  -P 自动将容器中所有通过 EXPOSE 声明的端口映射到宿主机的高位随机端口（范围通常为 32768~60999）
docker run -v 宿主机路径:容器内路径[:options] 镜像 # 将宿主机上的指定目录/文件挂载到容器内指定位置  options: 1.ro：Read-Only，容器内对该路径只读（宿主机可读写）2.rw：Read-Write，容器内可对该路径读写（默认值）
docker run --volumes-from 源容器名或ID 镜像 # 继承源容器的数据卷
docker attach 容器ID # 直接进入容器启动命令的终端，不会启动新的进程，用exit退出，会导致容器的停止
docker exec -it 容器ID bash # 是在容器中打开新的终端，并且可以启动新的进程，用exit退出，不会导致容器的停止
docker logs 容器 # 查看容器日志
docker top 容器ID # 查看容器内运行的进程
docker inspect 容器ID # 查看容器内部细节
docker stop 容器ID或者容器名 # 停止容器
docker kill 容器ID或容器名 # 强制停止容器
docker start 容器ID或者容器名 # 启动已停止运行的容器
docker restart 容器ID或者容器名 # 重启容器
docker rm 容器ID # 删除已停止的容器
docker rm -f $(docker ps -a -q) # 删除本地全部容器
docker ps -a -q | xargs docker rm # 删除本地全部容器
docker cp  容器ID:容器内路径 目的主机路径 # 从容器内拷贝文件到主机上
```