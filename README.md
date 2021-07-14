# Deploy Submariner

## 部署之前

1. 在本地机器安装 `ansible`

   - MacOS: `brew install ansible`
   - Ubuntu: [installing-ansible-on-ubuntu](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-ansible-on-ubuntu)
   - CentOS: [installing-ansible-on-rhel-centos-or-fedora](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html#installing-ansible-on-rhel-centos-or-fedora)

1. 准备 >= 2 个 Ubuntu 的节点，将本地节点的 `~/.ssh/id_rsa.pub` 添加到准好的节点 `root` 用户下的 `/root/.ssh/authorized_keys` 的文件里，让本地机器可以无密码访问远端节点。

   - CPU >= 2 cores
   - Memory >= 4G

后面的脚本会用这几个节点来搭建 k8s 集群，并部署 submariner，将所有的节点 join 到 submariner 的 broker。

## 快速开始

1. Clone code source

    ```shell
    git clone https://github.com/DanielXLee/deploy-submariner.git
    ```

1. 如果你的远程节点不能访问外部的网络，需要设置一个代理服务，如果可以访问外网，则跳过此步骤

    测试是否能够访问外网

    ```shell
    docker pull k8s.gcr.io/pause:3.2
    ```

    在脚本 `setup-k8s-cluster.sh` 中找到 `PROXY_SERVER` 和 `PROXY_PORT`, 替换为你自己的代理 `IP` 和 `Port`

1. Update `inventory` file template with your nodes IP

    Update `<cluster-x-public-ip>` with your remote node public IP

    ```shell
    [broker]
    <cluster-a-public-ip> pod_cidr=10.44.0.0 service_cidr=10.45.0.0 cluster_name=cluster-a

    [managed]
    <cluster-b-public-ip> pod_cidr=10.144.0.0 service_cidr=10.145.0.0 cluster_name=cluster-b
    <cluster-c-public-ip> pod_cidr=10.244.0.0 service_cidr=10.245.0.0 cluster_name=cluster-c
    ```

1. Start deploy submariner with command: `./quick-start.sh`
