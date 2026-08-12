# RK3588 StarryOS iperf3 快速测试

该 app 用于 Orange Pi 5 Plus（RK3588）。默认完成一次 TCP TX 和一次 TCP RX，测试参数
与现有 RK3588 性能基线一致：`-t 10 -O 2 -P 1 -l 128K`。进入 StarryOS 后 30 秒内
即可得到结果，不运行耗时的完整参数矩阵，也不设置与机器绑定的吞吐门槛。

## 快速运行

宿主机启动 iperf3 server：

```bash
iperf3 -s -p 5201
```

另开终端，在仓库根目录启动板测：

```bash
cargo xtask starry app board -t iperf3 -b OrangePi-5-Plus
```

看到下面三行即表示测试通过：

```text
STARRY_IPERF3_TCP_UPLOAD_OK
STARRY_IPERF3_TCP_DOWNLOAD_OK
STARRY_IPERF3_APP_PASSED
```

如果宿主机已经有 iperf3 server 在 5201 端口运行，只需要执行第二条命令。

## 已经进入 StarryOS 时

不需要重新启动板卡。先在宿主机查询访问板卡时使用的本机地址；将
`192.168.88.2` 替换为板卡地址：

```bash
ip -4 route get 192.168.88.2
```

输出中 `src` 后面的 IPv4 地址就是宿主机地址。在宿主机启动 server：

```bash
iperf3 -s -p 5201
```

然后在 StarryOS shell 执行以下两条命令，并将 `192.168.88.1` 替换为上一步查到的
宿主机地址：

```bash
# RK3588 TX：板卡发送，宿主机接收
iperf3 -c 192.168.88.1 -p 5201 -t 10 -O 2 -P 1 -l 128K

# RK3588 RX：宿主机发送，板卡接收
iperf3 -c 192.168.88.1 -p 5201 -t 10 -O 2 -P 1 -l 128K -R
```

## 测试做了什么

`board-orangepi-5-plus.toml` 会把 `${boardServerIp}` 解析为 RK3588 能访问的宿主机地址，
然后把 `init.sh` 注入 StarryOS shell。脚本依次执行：

```text
TCP_UPLOAD:   iperf3 client on RK3588 -> host server
TCP_DOWNLOAD: host server -> iperf3 client on RK3588 (--reverse)
```

每项结果以 JSON 打印到串口，同时保存在 StarryOS：

```text
/tmp/starry-iperf3/TCP_UPLOAD.json
/tmp/starry-iperf3/TCP_DOWNLOAD.json
```

只有两项 iperf3 都成功、JSON 非空、包含完整的 `end` 对象且没有 `error` 字段，脚本才会
输出最终成功标记。成功表示 iperf3 和 TCP 正反向数据路径可用，不代表达到某个固定速率。

## 可选参数

默认参数位于 `board-orangepi-5-plus.toml`：

| 环境变量 | 默认值 | 作用 |
| --- | --- | --- |
| `IPERF3_SERVER` | `${boardServerIp}` | 宿主机 iperf3 地址 |
| `IPERF3_PORT` | `5201` | iperf3 端口 |
| `IPERF3_DURATION` | `10` | 每个方向的有效测量秒数 |
| `IPERF3_OMIT` | `2` | 不计入结果的预热秒数 |
| `IPERF3_PARALLEL` | `1` | TCP 并行流数量 |
| `IPERF3_BLOCK_SIZE` | `128K` | iperf3 读写块大小 |

需要固定的新档位时，复制 board TOML、修改参数，再显式传入配置：

```bash
cargo xtask starry app board -t iperf3 \
  --board-config board-orangepi-5-plus-custom.toml \
  -b OrangePi-5-Plus
```

比较两个内核版本时，应保持板卡、rootfs、网线、宿主机、iperf3 版本和上述参数一致，
并重复至少三次后比较中位数。单次快速测试适合确认功能和性能量级，不适合声称稳定的性能
提升。

## 只在失败时检查

1. StarryOS 执行 `command -v iperf3`，确认 eMMC rootfs 已有 iperf3；
2. 宿主机确认 `iperf3 -s -p 5201` 正在运行；
3. 确认 RK3588 能访问宿主机，且防火墙允许 5201/TCP；
4. 查看串口 JSON 的 `error` 字段。

若 eMMC rootfs 缺少 iperf3，先在板载 Linux 安装一次并落盘：

```bash
sudo apt-get update && sudo apt-get install -y iperf3
sync
```

参数语义以 [iperf3 官方手册](https://software.es.net/iperf/invoking.html) 为准。CI 级短时
连通性用例仍位于 `test-suit/starryos/board-orangepi-5-plus/iperf-smoke/`；本 app 面向用户
快速运行和记录 RK3588 TCP 性能。
