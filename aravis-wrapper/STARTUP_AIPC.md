# BZ-10 相机：AIPC 开机后启动与奇偶预览

适用连接：BZ-10 `end0` 水晶头接 AIPC `eno1`；BZ-10 FH1223 SFP4 光口接 AIPC USB4 适配器 SFP1。控制网为 BZ-10 `192.168.50.2/24`、AIPC `192.168.50.1/24`。光口 `ens1f0` 接收 BZCAMRAW 二层包，不配置 IP。

## 每次重启后的命令（在 AIPC 图形桌面的终端运行）

```sh
cd /path/to/bz10-fpga-aravis-camera/aravis-wrapper
bash ./start_after_boot.sh
nix-shell -p aravis --run 'arv-viewer-0.8 --auto-buffer-size --no-packet-resend'
```

脚本会检查控制网与光口、授权 `DM7801BJ` USB4 适配器、通过 SSH 在 BZ-10 启动控制程序，并在 AIPC 启动 GigE Vision wrapper。SSH 会提示输入 BZ-10 的 root 密码；若需要 AIPC 的 sudo 密码，也会在终端提示。脚本只准备链路，**不会主动开始拍摄**。在 Viewer 中选择 `Aravis-Fake-BZ10-CAM0`，点击播放才会启动 BZ-10；点击停止会令 BZ-10 回到 `run=0`。

若要核对实际状态，在 AIPC 终端运行：

```sh
ip -br addr show eno1
ip -br link show ens1f0
printf 'STATUS\n' | nc -N -w 2 192.168.50.2 5090
systemctl is-active bz10-gige-wrapper
```

`STATUS` 播放时应为 `OK run=1 fps=50`，停止后应为 `OK run=0 fps=50`。本脚本创建的是临时 systemd 服务；下次重启仍需重新运行脚本。`eno1` 的固定 IP 和 SSH 防火墙设置已证明可以保留，USB4 授权不会保留。

## 在同一个 Viewer 画面中切换奇数和偶数

Viewer 保持播放，在 AIPC 的**另一个终端**执行其中一条：

```sh
bash ./set_preview_parity.sh odd
bash ./set_preview_parity.sh even
bash ./set_preview_parity.sh all
```

`all` 显示全部帧，约 50 fps；`odd` 和 `even` 分别显示原始帧号为奇数或偶数的完整帧，约 25 fps。切换时相机仍以 **50 Hz** 触发，FPGA 的 J5 奇偶输出也照常翻转；只改变 AIPC 送入 Viewer 的图像，**不改变曝光、触发频率或 PL 光口输出**。不必重启 Viewer 或 BZ-10。每次 Viewer 从停止变为播放，BZCAMRAW v2 的输入 `frame_id` 从 1 开始；奇偶分组依据 `(run_id, frame_id)` 中的 `frame_id`，不要根据 Aravis 的 GVSP 帧号分组。

设计约定是 J5 在奇数次触发为高、偶数次为低，因此 `odd` 对应**预期高电平**。目前已验证包内帧号重新从 1 计数和奇偶过滤；J5 的实际电平与相机 CSI SOF 尚未做同步示波器测量。若外部 LED 驱动器反相，实际亮暗标签也要按测量结果修正。

2026-10-31 的真实光口连续测试在不停止采集的情况下切换 `all → odd → even`：客户端帧率由约 50 降为约 25，472 个 RGB8 缓冲完成，0 失败、0 GVSP 缺包；元数据确认 odd 阶段只输出奇数 `input_frame_id`，even 阶段只输出偶数。测试后 BZ-10 返回 `run=0 fps=50`。

## 脚本执行的关键命令

下面是上述流程在 AIPC 上执行的核心命令，便于逐项排查；正常启动时运行脚本即可。USB4 的 `1-2` 路径取决于插入位置，脚本会按设备名查找。

```sh
echo 1 | sudo tee /sys/bus/thunderbolt/devices/1-2/authorized
ssh root@192.168.50.2 'echo 0 > /sys/bus/platform/devices/80040000.cam0-raw10g-trigger/run; systemd-run --unit=bz10-camera-control --collect /home/root/bz10_control_agent 192.168.50.2 5090 /sys/bus/platform/devices/80040000.cam0-raw10g-trigger'
printf 'all\n' > ./preview-parity.txt
sudo systemd-run --unit=bz10-gige-wrapper --collect "$PWD/bz10_gige_wrapper" --input ens1f0 --listen 192.168.50.1 --control 192.168.50.2:5090 --fps 50 --parity-file "$PWD/preview-parity.txt" --metadata /tmp/bz10_viewer_mapping.csv
```

这些手工命令只适合服务尚未启动时执行；重复启动会因 systemd 单元名或元数据文件已存在而失败。脚本会跳过已运行的服务，并为元数据使用新的文件名。
