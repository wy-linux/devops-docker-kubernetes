# 基础镜像 (必须第一个指令)
FROM ubuntu:24.04

# 维护者信息 (已弃用，推荐使用LABEL)
LABEL maintainer="wangyu.sudo@gmail.com"

# 设置环境变量 (构建过程和最终镜像中均可用)
ENV APP_HOME=/app \
    NODE_ENV=production

# 工作目录 (后续指令的默认执行路径，不存在则自动创建)
WORKDIR $APP_HOME

# 复制文件 (从宿主机复制到镜像)
COPY package.json ./

# 运行构建命令 (执行shell命令，会创建新镜像层)
RUN apt-get update && \
    apt-get install -y nodejs npm

# 挂载点声明 (容器运行时自动挂载为卷)
VOLUME ["/app/logs"]

# 暴露端口 (声明容器运行时监听端口，需配合-p映射)
EXPOSE 3000

# 添加文件 (类似COPY，但支持URL和解压tar包)
ADD https://wangyu.com/wangyu.tar.gz /wangyu

# 健康检查 (容器启动后检查服务状态)
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:3000/ || exit 1

# 用户切换 (切换后续指令的执行用户)
USER wangyu

# 入口点 (容器启动时执行的命令)
ENTRYPOINT ["npm"]

# 启动命令 (ENTRYPOINT的参数，可被docker run覆盖)
CMD ["start"]