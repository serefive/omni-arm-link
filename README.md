# omni-arm-link

面向比赛机器人的低延迟、双向 IEEE 802.11 原始链路通信栈，基于
**WFB-NG + RTL8812EU** 构建。

本项目实现了 [`通信方案.md`](通信方案.md) 中描述的应用层与协议层：

- **Controller（遥控器端）**（Raspberry Pi 4B）：摇杆 / 按键 / 模式 / 急停
- **Robot（机器人端）**（NVIDIA Jetson Orin）：200 Hz 发送 5 组四元数 +
  15 个激光数据 + 50 个状态量（约 544 kbps 原始负载，约 1 Mbps 链路预算）
- **Monitor（第三节点）**：被动、只收的数据包记录与链路分析

WFB-NG 提供 Monitor Mode、原始帧注入、FEC 与加密。本仓库提供自定义机器人
协议、三个应用程序、WFB-NG 配置、配置脚本以及测试/仿真工具。

---

## 系统架构

```
                    ┌──────────────────┐
                    │    Monitor       │
                    │ oal_monitor      │  只收，JSONL 记录 + 统计
                    └────────▲─────────┘
                             │ 被动接收（上下行）
                             │
┌────────────────────┐              ┌────────────────────┐
│   Controller       │              │       Robot        │
│   oal_controller   │              │   oal_robot        │
│   RPi 4B           │              │   Jetson Orin      │
└─────────┬──────────┘              └─────────┬──────────┘
          │ UDP（本机）                        │ UDP（本机）
          ▼                                    ▼
     wfb_tx / wfb_rx                       wfb_tx / wfb_rx
          │                                    │
          └──────── Raw IEEE 802.11 ───────────┘
                    (WFB-NG, RTL8812EU)
```

应用程序不会直接操作无线网卡，而是与本机的 `wfb_tx` / `wfb_rx` 进程交换 UDP
数据报，由 WFB-NG 完成 FEC、加密以及原始帧注入 / Monitor Mode 接收。

### 逻辑数据流

| 流   | ID   | 方向                 | 速率    | FEC        | 用途                   |
|------|------|----------------------|---------|------------|------------------------|
| 0    | 0x01 | Robot → Controller   | 200 Hz  | K=8 N=12   | 核心遥测               |
| 1    | 0x02 | Robot → Controller   | ~5 Hz   | K=4 N=8    | 调试 / 日志            |
| 2    | 0x80 | Controller → Robot   | 200 Hz  | K=1 N=3    | 控制（最高优先级）     |
| test | 0x7E | Robot → Controller   | 可配置  | K=2 N=4    | 链路测试               |
| test | 0xFE | Controller → Robot   | 可配置  | K=2 N=4    | 链路测试               |

低优先级的调试数据为独立数据流，绝不会阻塞控制数据。

---

## 线上协议

每个 UDP 数据报承载恰好一个帧：

```
FrameHeader（28 字节，小端）
  u32 magic          0x314C414F ("OAL1")
  u8  version        1
  u8  stream         逻辑流 ID
  u16 flags          bit0 急停, bit1 心跳, bit2 应答, bit3 关键
  u32 seq            每流序列号
  u64 timestamp_ns   发送方墙上时钟（epoch）纳秒
  u16 payload_len
  u16 reserved
  u32 payload_crc    负载的 CRC-32 (IEEE)
```

负载：

- **遥测 Telemetry**（340 B）：`float[5][4]` 四元数、`float[15]` 激光、
  `float[50]` 状态量 —— 与比赛要求的格式完全一致。
- **控制 Control**（36 B）：`float[4]` 轴、`u16` 按键、`u8` 模式、
  `u8` 标志、`float[4]` 控制参数。
- **调试 Debug**（变长）：等级 + 长度前缀的 UTF-8 文本。

帧 CRC 与 magic 使得在 WFB-NG 自身完整性校验之上，仍可在应用层检测出损坏或
外来的数据包。

---

## 构建

依赖：CMake ≥ 3.16、C++17 编译器、pthread。无需任何第三方库。

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
```

可执行文件：`oal_robot`、`oal_controller`、`oal_monitor`、`oal_linktest`、`oal_sim`。

常用选项：`-DOAL_BUILD_TOOLS=OFF`、`-DOAL_WARNINGS_AS_ERRORS=ON`、
`-DOAL_ENABLE_ASAN=ON`。

---

## 无电台快速开始（仿真）

仿真工具使用普通 UDP，并复现完全相同的应用层协议，因此整条链路可在一台主机上
验证：

```bash
# 终端 1：被动监听
./build/oal_monitor --duration 10 --no-measure-latency

# 终端 2：仿真机器人，向监听端的遥测端口发送
./build/oal_sim robot --dest 127.0.0.1:5622 --rate 200 --loss 0.02 --jitter-ms 2

# 终端 3：仿真遥控器，向监听端的控制端口发送
./build/oal_sim controller --dest 127.0.0.1:5621 --rate 200
```

也可以把真实应用程序直接对接（绕过 WFB-NG）：

```bash
./build/oal_robot --telemetry-tx 127.0.0.1:5612 --debug-tx 127.0.0.1:5613 \
                  --control-port 5601
./build/oal_controller --telemetry-port 5612 --debug-port 5613 \
                       --control-tx 127.0.0.1:5601 --interactive
```

### 双终端直连自测（模拟数据 + 实时打印）

开两个终端，一个当机器人端、一个当遥控器端，用合成数据互通，并用
`--print-rate HZ` 实时打印各自解码出的接收数据（0 = 关闭）。机器人端内置
合成遥测，遥控器端默认合成摇杆运动，无需电台：

```bash
# 终端 1：机器人端（接收控制，打印 control 数据）
./build/oal_robot --telemetry-tx 127.0.0.1:5612 --debug-tx 127.0.0.1:5613 \
                  --control-port 5601 --print-rate 5 --no-measure-latency

# 终端 2：遥控器端（接收遥测/调试，打印 telemetry 数据）
./build/oal_controller --telemetry-port 5612 --debug-port 5613 \
                       --control-tx 127.0.0.1:5601 --print-rate 2 --no-measure-latency
```

终端 1 会持续打印 `rx control seq=... mode=... buttons=... estop=... axes=[...]`，
终端 2 会打印 `rx telemetry seq=...`（四元数、激光、状态量）与 `rx debug:` 文本。
停止终端 2 后，终端 1 应在 `--control-timeout-ms`（默认 500 ms）内进入 SAFE。

---

## 配合 WFB-NG 部署

### 1. 安装驱动 + WFB-NG（每台主机一次）

```bash
sudo scripts/install_wfbng.sh 8812eu
```

### 2. 生成密钥对

密钥的生成方式详见 [通信方案](通信方案.md)。本仓库以 `config/keys` 为唯一密钥来源，生成密钥：

```bash
scripts/gen_keys.sh config/keys
```

部署时直接分发这些密钥即可。

占位符说明：

- `<robot-user>@<robot-host>`：机器人 SSH 登录目标，如 `user@host`
- `<controller-user>@<controller-host>`：遥控器 SSH 登录目标，本机可用 `local`
- `<robot-wlan>` / `<controller-wlan>` / `<monitor-wlan>`：对应主机的无线网卡名，用 `ip -brief link` 查看
- `<robot-repo>` / `<controller-repo>`：各主机上本仓库的路径，如 `~/omni-arm-link`

#### 密钥校验

```bash
sha256sum config/keys/drone.key config/keys/gs.key
```

#### 分发密钥：机器人端（系统级）

密钥放到 `/etc`：

```bash
scp config/keys/drone.key <robot-user>@<robot-host>:/tmp/drone.key
ssh <robot-user>@<robot-host> \
  'sudo install -m600 -o root -g root /tmp/drone.key /etc/drone.key && rm -f /tmp/drone.key'
```

#### 分发密钥：遥控器端（用户级）

密钥放到运行 `wfb-server` 的用户的 `$HOME/.local/etc`：

```bash
install -Dm600 config/keys/gs.key "$HOME/.local/etc/gs.key"
```

> **注意：** 用户级安装时，密钥必须放到实际运行 `wfb-server` 的用户的
> `$HOME/.local/etc` 下，而不是 `/etc`。遥控器只使用 `gs.key`；若该主机同时
> 充当被动监听端，则需要把两个密钥都更新。

#### 被动监听端

被动监听端（无论系统级还是用户级）需要同时具备 `drone.key` 和 `gs.key`：

- 系统级：`/etc/drone.key`、`/etc/gs.key`
- 用户级：`$HOME/.local/etc/drone.key`、`$HOME/.local/etc/gs.key`
install -Dm600 config/keys/gs.key "$HOME/.local/etc/gs.key"

#### 启动 WFB-NG

机器人端（系统级）：

```bash
ssh <robot-user>@<robot-host>
cd <robot-repo>
sudo scripts/wfb_server.sh robot <robot-wlan>
```

遥控器端（用户级，普通用户执行 `sudo`）：

```bash
cd <controller-repo>
sudo scripts/wfb_server.sh controller <controller-wlan>
```

被动监听端：

```bash
sudo scripts/wfb_server.sh monitor <monitor-wlan>
```

#### 确认密钥路径

```bash
pgrep -af 'wfb-server|wfb_tx|wfb_rx'
```

- 机器人应出现 `-K /etc/drone.key`
- 遥控器应出现 `-K /home/<user>/.local/etc/gs.key`

如果路径与预期不符，说明启动到了另一套安装（系统级/用户级）或旧进程未清理。

### 3. 配置各主机

```bash
# 在机器人端
sudo scripts/setup_radio.sh robot <robot-wlan> --start

# 在遥控器端
sudo scripts/setup_radio.sh controller <controller-wlan> --start

# 在监听端（只收，发射功率关闭）
sudo scripts/setup_radio.sh monitor <monitor-wlan> --start
```

该脚本会安装 `/etc/wifibroadcast.cfg`、复制密钥、校验驱动并启动 WFB-NG
配置。三台主机必须使用相同的 `wifi_channel` 与 `link_domain`
（参见 `config/wifibroadcast-*.cfg`）。

### 4. 运行应用程序

```bash
scripts/run_robot.sh          # 在机器人端
scripts/run_controller.sh     # 在遥控器端（加 --interactive 使用按键）
scripts/run_monitor.sh        # 在监听端
```

或安装随附的 systemd 单元：

```bash
sudo install -Dm644 systemd/oal-robot.service /etc/systemd/system/oal-robot.service
# ... controller、monitor 同理
sudo systemctl enable --now oal-robot
```

WFB-NG 的链路统计可独立于本项目获取：

```bash
wfb-cli robot      # 或 controller / monitor
```

#### 随机数据链路测试（可选）

不启动完整应用时，也可以用 `oal_linktest` 通过 WFB-NG 测试流发送随机生成的
负载，验证空口收发。`--random` 会把每个探测包负载填充为随机字节（首字节保留
ping/pong 标记），延迟、丢包与 FEC 统计和普通测试完全一致：

```bash
# 机器人端（应答方）
scripts/link_test.sh robot --random --size 340

# 遥控器端（发起方，30 秒后自动退出）
scripts/link_test.sh controller --random --size 340 --duration 30

# 测试结束后生成汇总报告
scripts/link_test.sh report
```

两台主机各用一块网卡时，可让双机测试脚本在两端都启用随机负载：

```bash
scripts/link_test_2host.sh run \
    --robot pi@robot.local --controller pi@controller.local \
    --robot-arg --random --controller-arg --random
```

### 5. 两台主机各一块网卡链路测试（虚拟数据）

前置条件：两台主机都已按第 1–3 步安装 WFB-NG、复制密钥，并分别用各自的网卡
启动了对应 profile（机器人端 `wfb-server robot <wlan>`，遥控器端
`wfb-server controller <wlan>`）。两块网卡必须使用相同的 `wifi_channel` 与
`link_domain`。两台主机之间需配置免密 SSH，且仓库已在两端构建完成。

`scripts/link_test_2host.sh` 会通过 WFB-NG 的测试流（0xFE/0x7E）发送合成
ping/pong 数据（默认 340 B），不依赖真实传感器或摇杆。在任意一台主机上执行
下面这一条命令，即可自动启动两端测试、取回两份报告并生成汇总：

```bash
scripts/link_test_2host.sh run \
    --robot pi@robot.local --controller pi@controller.local \
    --duration 30 --rate 200 --size 340
```

- `--robot` / `--controller`：两端的 SSH 目标；本机可写 `local`。
- `--robot-repo` / `--controller-repo`：两端仓库路径，默认与当前仓库相同。
- `--dir`：汇总报告目录，默认 `/tmp/oal-linktest-2host`。
- `--remote-dir`：两端报告临时目录，默认 `/tmp/oal-linktest`。
- `--robot-arg` / `--controller-arg`：透传给 `oal_linktest` 的额外参数（可重复）。

如果已手工在两台主机上分别运行了 `scripts/link_test.sh robot` 和
`scripts/link_test.sh controller`，测试结束后只需执行下面这一条命令，即可
通过 SSH 取回两份报告并生成汇总：

```bash
scripts/link_test_2host.sh report \
    --robot pi@robot.local --controller pi@controller.local
```

报告包含上下行 TX/RX、丢包/重复/乱序、往返延迟 p50/p95/p99/max、FEC 恢复率
（两端 `wfb-server` 的 `api_port` 可访问时）以及 PASS/FAIL 判定，并同时保存为
`<dir>/report.txt`。阈值沿用 `OAL_LINK_MAX_LOSS_PCT`（默认 5）和
`OAL_LINK_MAX_P99_MS`（默认 100）；设置 `OAL_LINK_MIN_FEC_RECOVERY_PCT` 可将
最低 FEC 恢复率纳入判定。SSH 参数可通过 `OAL_SSH_OPTS` 覆盖。

> 两台主机必须实际启动 `wfb-server`。否则测试数据不会进入 WFB-NG，报告通常
> 会显示 `FAIL no-traffic`，FEC 数据也不可用。

### 6. 单机双电台自测（机器人 + 遥控器同机）

只需一台主机、两块支持 Monitor Mode + 注入的无线网卡（例如两块 RTL8812EU），
即可在一台机器上同时充当机器人端与遥控器端，跑通完整的 WFB-NG 空口链路。
两块网卡使用相同信道（`wifi_channel = 165`）与 `link_domain`，一块（`<robot-wlan>`）
作机器人，另一块（`<controller-wlan>`）作遥控器。

两份 profile 的 `stats_port` / `api_port`（8002/8102 与 8003/8103）本就不同，
因此两个 `wfb-server` 实例可以并存。遥测/控制仍走 `127.0.0.1`；链路测试的
接收端绑定 `127.0.0.2`（`wfb_rx` 也转发到该地址），避免与同机 `wfb_tx`
在 5631/5632 上的监听端口冲突，同时仍能通过本机回环把数据送进 WFB-NG。

```bash
# 1. 装驱动 + 生成密钥
sudo scripts/install_wfbng.sh 8812eu
scripts/gen_keys.sh config/keys
sudo install -m600 config/keys/drone.key config/keys/gs.key /etc/

# 2. 合并 profile：以 robot 配置为基础，追加 controller 专有部分
sudo cp config/wifibroadcast-robot.cfg /etc/wifibroadcast.cfg
sudo tee -a /etc/wifibroadcast.cfg >/dev/null <<'EOF'

[gs_base]
keypair = 'gs.key'

[controller]
streams = [
    {'name': 'telemetry', 'stream_tx': None, 'stream_rx': 0x01, 'service_type': 'udp_direct_rx',
     'profiles': ['base', 'radio_base', 'gs_base'],
     'peer': 'connect://127.0.0.1:5612'},
    {'name': 'debug', 'stream_tx': None, 'stream_rx': 0x02, 'service_type': 'udp_direct_rx',
     'profiles': ['base', 'radio_base', 'gs_base'],
     'peer': 'connect://127.0.0.1:5613'},
    {'name': 'control', 'stream_tx': 0x80, 'stream_rx': None, 'service_type': 'udp_direct_tx',
     'profiles': ['base', 'radio_base', 'gs_base', 'control_fec'],
     'peer': 'listen://127.0.0.1:5611'},
    {'name': 'test_up', 'stream_tx': 0xFE, 'stream_rx': None, 'service_type': 'udp_direct_tx',
     'profiles': ['base', 'radio_base', 'gs_base', 'test_fec'],
     'peer': 'listen://127.0.0.1:5631'},
    {'name': 'test_down', 'stream_tx': None, 'stream_rx': 0x7E, 'service_type': 'udp_direct_rx',
     'profiles': ['base', 'radio_base', 'gs_base'],
     'peer': 'connect://127.0.0.2:5632'}
    ]
stats_port = 8003
api_port = 8103
link_domain = 'oal-link'
EOF

# 3. 调好两块网卡
for w in <robot-wlan> <controller-wlan>; do
    sudo ip link set "$w" up
    sudo ip link set "$w" mtu 2312 txqueuelen 1000
done
sudo iw reg set BO

# 4. 起两个 WFB-NG 实例（同信道、同 link_domain）
sudo scripts/wfb_server.sh robot      <robot-wlan> &
sudo scripts/wfb_server.sh controller <controller-wlan> &
ss -ltnup | grep -E '563[12]|810[23]'   # 563x=UDP wfb_tx；810x=TCP 统计 API
wfb-cli robot          # 另一个终端查看射频统计（controller 同理）

# 5. 跑应用（均使用 config/link.conf，走 127.0.0.1）
./build/oal_robot      --config config/link.conf &
./build/oal_controller --config config/link.conf --interactive

# 6. 双向往返链路测试（可选；两个终端，先起应答方）
# 终端 A（responder）
scripts/link_test.sh robot
# 终端 B（initiator）
scripts/link_test.sh controller --size 340

# 7. 先在终端 B Ctrl-C，再在终端 A Ctrl-C；然后任一端执行
scripts/link_test.sh report
```

如果 wfb-ng 是用 `pip --user` 安装的（`wfb-server` 位于 `~/.local/bin`），
直接 `sudo wfb-server` 会因 root 的 `PATH`/`PYTHONPATH` 不同而报
`command not found`；`scripts/wfb_server.sh` 会自动补上用户级安装路径。

链路测试必须让两个 `wfb-server` 先成功启动：`linktest` 发到
`127.0.0.1:5631`（上行测试流）和 `127.0.0.1:5632`（下行测试流）的数据会进入
`wfb_tx`，经空口后由对端 `wfb_rx` 转发到 `127.0.0.2:5631/5632` 交给
`linktest`。若 `wfb-server` 没起来，两个 `linktest` 会直接在回环上互通，
看起来也能跑通，但完全没有经过 WFB-NG，报告里也不会有 FEC 数据。测试过程中
可另开终端运行 `wfb-cli robot` / `wfb-cli controller`，确认 `recv` / `fec_r`
计数随测试增长。

测试结束时，两端会分别把结果写入 `/tmp/oal-linktest/robot.report` 和
`/tmp/oal-linktest/controller.report`（可用 `OAL_LINKTEST_REPORT_DIR` 改目录）。
`report` 子命令读取这两个文件，打印上下行收发/丢包/往返延迟分位数与 PASS/FAIL
判定；也可直接运行 `scripts/link_report.sh --dir DIR`。非交互场景可加
`--duration N` 让两端自动退出（robot 多跑 5 s，确保覆盖 controller 的结束）：

```bash
scripts/link_test.sh robot --duration 35 &
sleep 1
scripts/link_test.sh controller --duration 30 --size 340
wait
scripts/link_test.sh report
```

如果本机 `wfb-server` 的 JSON 统计接口可访问（robot profile `api_port = 8102`，
controller profile `api_port = 8103`），测试开始和结束时会各采样一次 WFB-NG 的
接收计数器。可先手动探测：

```bash
scripts/wfb_stats.py --port 8102 --service test_up
scripts/wfb_stats.py --port 8103 --service test_down
```

能输出 `fec_rec=...`、`lost=...` 即正常。报告因此会额外给出上下行的
**FEC 恢复率**：

- `Recovered`：窗口内经 FEC 恢复的包数（`fec_rec` 增量）
- `Lost`：FEC 之后仍然丢失的包数（`lost` 增量）
- `Recovery %`：`fec_rec / (fec_rec + lost)`
- `K/N`：该流实际协商到的 FEC 编码参数

链路完全干净时没有丢块，`Recovered` 和 `Lost` 都会是 0，恢复率显示为 `n/a`；
要验证 FEC，可适当降低发射功率、增加距离/遮挡或使用更弱的 FEC 配置来制造空口丢块。

可用 `OAL_WFB_API_HOST`、`OAL_WFB_API_PORT`、`OAL_WFB_TEST_SERVICE` 覆盖默认
采样地址/服务名；`OAL_WFB_API_PORT=0` 关闭采样。若要把恢复率纳入 PASS/FAIL，
设置 `OAL_LINK_MIN_FEC_RECOVERY_PCT`（默认 0，表示只报告不判定）。

判定标准：机器人端打印 `control <- 0.0.0.0:5601` 后不再报 SAFE，遥控器端持续输出
遥测统计；在 `--interactive` 下按 `a d e m c q` 验证按键与急停。停止遥控器后，
机器人端应在 `control_timeout_ms`（默认 500 ms）内进入 SAFE 状态。

---

## 命令行参考

所有选项也可写入配置文件（`config/link.conf`），并由命令行覆盖。

### `oal_robot`

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--rate` | 200 | 遥测速率（Hz） |
| `--telemetry-tx` | 127.0.0.1:5602 | 遥测的 WFB-TX 端点 |
| `--debug-tx` | 127.0.0.1:5603 | 调试的 WFB-TX 端点 |
| `--control-port` | 5601 | 控制的本机 WFB-RX 端口 |
| `--control-timeout-ms` | 500 | 控制丢失后进入 SAFE 状态的超时 |
| `--debug-rate` | 5 | 调试流速率（Hz） |
| `--duration` | 0 | 运行秒数（0 = 一直运行） |
| `--print-rate` | 0 | 实时打印收到的控制帧（Hz，0 = 关闭） |
| `--no-measure-latency` | | 关闭单向延迟测量（时钟未同步时） |

### `oal_controller`

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--rate` | 200 | 控制速率（Hz） |
| `--telemetry-port` | 5612 | 遥测的本机 WFB-RX 端口 |
| `--debug-port` | 5613 | 调试的本机 WFB-RX 端口 |
| `--control-tx` | 127.0.0.1:5611 | 控制的 WFB-TX 端点 |
| `--interactive` | false | 从 stdin 读取 `a d e m c q` 命令 |
| `--no-auto-motion` | | 停止合成摇杆运动 |
| `--print-rate` | 0 | 实时打印收到的遥测/调试帧（Hz，0 = 关闭） |
| `--telemetry-timeout-ms` | 500 | 遥测缺失时告警的超时 |

### `oal_monitor`

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--telemetry-port` | 5622 | 遥测的本机 WFB-RX 端口 |
| `--debug-port` | 5623 | 调试的本机 WFB-RX 端口 |
| `--control-port` | 5621 | 控制的本机 WFB-RX 端口 |
| `--log-file` | `monitor-<时间>.jsonl` | 逐帧 JSONL 日志 |--control-port
| `--no-frame-log` | | 关闭逐帧记录 |

### `oal_linktest`

```bash
# 两个终端：先起应答方，再起发起方
scripts/link_test.sh robot                    # responder（应答方）
scripts/link_test.sh controller --size 340    # initiator（发起方）

# 先停 controller，再停 robot；然后一条命令打印汇总报告
scripts/link_test.sh report

# 或非交互运行（robot 多跑 5 s）
scripts/link_test.sh robot --duration 35 &
sleep 1
scripts/link_test.sh controller --duration 30 --size 340
wait
scripts/link_test.sh report
```

单机双电台时，`linktest` 发送到 `127.0.0.1:5631/5632`（交给 `wfb_tx`），
接收端默认绑定 `127.0.0.2:5631/5632`，避免与同机 `wfb_tx` 的 UDP 监听端口冲突。
无需时钟同步即可报告双向的往返延迟分位数（p50/p95/p99/max）、抖动与丢包。
每次运行会写出 `--report PATH` 指定的报告文件（`link_test.sh` 默认写入
`/tmp/oal-linktest/<role>.report`）；`report` 子命令汇总两份文件，阈值可用
`OAL_LINK_MAX_LOSS_PCT`（默认 5）和 `OAL_LINK_MAX_P99_MS`（默认 100）调整。

测试期间 `link_test.sh` 还会从本机 `wfb-server` 的 `api_port` 采样 rx 计数器，
在报告中给出每个方向的 FEC 恢复包数、FEC 后丢失包数、FEC 恢复率及编码参数
`K/N`。默认
端口为 robot `8102`、controller `8103`；可用 `OAL_WFB_API_PORT`（设为 `0`
可关闭）、`OAL_WFB_API_HOST`、`OAL_WFB_TEST_SERVICE` 覆盖。设置
`OAL_LINK_MIN_FEC_RECOVERY_PCT` 可把最低恢复率纳入 PASS/FAIL 判定。

### `link_test_2host.sh`

```bash
# 两台主机各一块网卡：启动测试并自动生成汇总报告
scripts/link_test_2host.sh run --robot pi@robot.local --controller pi@controller.local

# 已手工跑完测试：只取回两端报告并生成汇总
scripts/link_test_2host.sh report --robot pi@robot.local --controller pi@controller.local

# 两端都通过 SSH 访问，仓库不在默认路径，并调整测试参数
scripts/link_test_2host.sh run \
    --robot root@robot --controller root@controller \
    --robot-repo /opt/omni-arm-link --controller-repo /opt/omni-arm-link \
    --duration 60 --rate 200 --size 340 --dir ./linktest-report
```

`run` 会先启动机器人端应答方（多运行 5 s），再启动遥控器端发起方；结束后通过
SSH 取回 `<remote-dir>/<role>.report` 及 FEC 采样文件，调用
`scripts/link_report.sh` 输出汇总并保存到 `<dir>/report.txt`。`report` 模式
只执行取回与汇总，不再启动测试。两端均需已启动 `wfb-server`，否则数据不会
经过 WFB-NG，报告会缺少 FEC 数据，并可能判定为 `FAIL no-traffic`。

### `oal_sim`

```bash
oal_sim robot --dest HOST:PORT --rate 200 --loss 0.05 --jitter-ms 5
oal_sim controller --dest HOST:PORT --rate 200 --estop
```

---

## 监控与日志

`oal_monitor` 对每个接收到的帧写入一个 JSON 对象：

```json
{"recv_ns":1729000000000000000,"direction":"robot->controller","stream":"telemetry",
 "seq":4211,"flags":0,"sender_ns":1729000000000000000,"size":368,"latency_ms":1.42}
```

它还会按流统计：包速率、吞吐量、序列丢包、重复、乱序、CRC 错误以及单向延迟
分位数。`crc_errors` 统计疑似损坏的帧，`bidirectional` 用于确认上下行均被观测
到。射频层面的实时丢包 / FEC 统计也可用 `wfb-cli` 查看，或由 `oal_linktest`
报告的 FEC 恢复率给出测试窗口内的汇总值。

**时钟同步：** 跨节点的单向延迟只有在两台主机时钟同步（例如通过 chrony/PTP）
时才有意义。若未同步，请使用 `--no-measure-latency`，并依赖 `oal_linktest`
的往返测量。

---

## 测试计划对应关系

| 通信方案测试 | 运行方式 |
|---|---|
| 1. 基础双向通信 | 双机：`scripts/link_test_2host.sh run --robot ... --controller ...`；单机：`scripts/link_test.sh robot` / `... controller`，结束后 `scripts/link_test.sh report`，再运行 `oal_robot` + `oal_controller` |
| 2. 延迟测试 | 汇总报告中的 p95/p99/max + `oal_monitor --measure-latency`（时钟已同步） |
| 3. 丢包 / 干扰测试 | `oal_sim ... --loss --duplicate --reorder --jitter-ms`，然后引入真实干扰；观察 PER、序列丢包、`oal_linktest` 的 FEC 恢复率与 `wfb-cli` 的实时统计 |
| 4. 第三节点监听 | 运行 `oal_monitor`；验证 `bidirectional=yes`、对主链路无影响，并获得完整 JSONL 日志 |
| 5. 比赛环境模拟 | 在密集 Wi-Fi、机器人运动、人体/金属遮挡及电机运行条件下重复测试 1–4 |

---

## 仓库结构

```
include/oal/        公共头文件（协议、编解码、传输、统计、配置）
src/                库实现 + robot / controller / monitor / tools
config/             WFB-NG 配置、应用配置、密钥目录
scripts/            安装 / 配置 / 运行辅助脚本
systemd/            三个应用的 service 单元
```
