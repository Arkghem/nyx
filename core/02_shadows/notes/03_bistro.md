# Bistro Exterior：大场景导入与首轮阴影测量

这一页记录「把 Bistro 塞进 02_shadows」时真正花时间的地方。结论先写在前面：
几何导入本身很便宜（首次导出约 1.5 s，之后四个机位共用一份 100 MiB 的
`.nxmesh`），便宜到可以把 2.84M 三角形当成日常场景；真正需要小心的是**资产
自带的坏法线、厘米单位、以及默认阴影剔除模式**。

## 为什么是它

Amazon Lumberyard Bistro Exterior 是 ORCA 里的经典大场景，许可为
[CC-BY 4.0](https://developer.nvidia.com/orca/amazon-lumberyard-bistro)：

- 2,832,120 三角形（G3D 的 OBJ 导出是 2,837,209，差异来自导出时的拆分）；
- 有大量自遮蔽：拱门、阳台、遮阳篷、灯柱、树、栏杆；
- 有开阔的广场和长街，适合同时看**接触阴影**和**长投影**；
- 只有一个方向光就能跑，和 02_shadows 现有的 `sm`/`pcf` 管线完全兼容。

G3D 的 `Exterior.zip` 只有 61 MiB（64.2 MB），里面是 `exterior.obj` + `exterior.mtl`，
**没有贴图**。这不是缺陷：阴影实验本来就不应该让纹理过滤参与判卷。两个渲染
器都用同一个常量反照率 `(0.62, 0.60, 0.56)`，几何和 BSDF 完全一致。

## 导入管线

```bash
python3 core/02_shadows/tools/bistro_scene.py all
```

四步各自可以单独跑：

| 步骤 | 做什么 | 产物 |
|---|---|---|
| `fetch` | 8 路 Range 并发下载、SHA-256 校验、解压 | `third_party/_deps/bistro/Exterior/exterior.obj` |
| `prepare` | 修零法线、去掉 `mtllib`/`usemtl`、写 manifest | `.cache/assets/bistro/exterior.obj` |
| `scenes` | 从机位表生成四个 Mitsuba XML | `core/02_shadows/scenes/bistro_*.xml` |
| `export` | 调 `scripts/export_scene.py --binary` | `.cache/scenes/bistro_*.nxscene` + `.nxmesh` |

`fetch` 不用 `curl` 是因为 G3D 对单连接限速很厉害；实测单连接约 50 KB/s，8 路
Range 并发能把 61 MiB 压到几分钟以内。zip 的 SHA-256 写死在工具里，下载完
先校验再解压。

## 四个坑

### 1. 一个零法线让整个网格加载失败

原始 OBJ 的第 4,078,730 行是：

```text
vn 0.000 0.000 -0.000
```

Mitsuba 的 OBJ 插件会把它当成 invalid vertex normal，直接拒绝整个 2.84M
三角形的 mesh。注意它**不是**警告后跳过，而是整个 shape 都加载不了：

```text
[OBJMesh] Error while loading OBJ file "exterior.obj": mesh contains invalid vertex normal data
```

`prepare` 的做法是流式扫描，遇到长度平方为 0（或非有限）的 `vn` 就用上一个
合法法线替代。整个文件只有 1 个这样的法线。不要为了这一个法线去重新计算全
场景法线：Bistro 的硬边/软边信息是有意义的，重算会改变着色。

MTL 里有 132 个材质定义，但 G3D 的 zip 不包含任何贴图；`prepare` 把
`mtllib`/`usemtl` 一起删掉，避免 Mitsuba 去找 132 份不存在的贴图。

### 2. 单位是厘米

OBJ 的包围盒（原始单位）：

```text
min = (-3903.64, -472.617, -5496.062)
max = ( 6956.373, 2720.772, 6030.092)
```

乘 0.01 之后是约 108 m × 32 m × 115 m，符合一个巴黎街区的尺度。**所有**
XML 都先 `<scale value="0.01"/>`，所以相机、`near_clip`/`far_clip`、shadow
bias 全部按米写。如果忘了这个 scale，相机会落在离建筑 100 倍远的地方，图像
会是空的，但导出器不会报错。

### 3. glTF/Bevy 的机位不能直接搬

Bistro 的 glTF 重导出（例如 bevy_bistro_scene）里有现成的 benchmark 机位，
例如 `(-10.5, 1.7, -1.0)`。直接拿来用会得到一张全黑图：G3D 的 OBJ 导出和
glTF 场景的根变换不一致，同一个坐标在 OBJ 里可能已经在墙里。最终四个机位是
在场景里实际渲染、看 albedo/normal/depth 调试视图后挑出来的，不是抄来的。

找机位时最有用的两个调试视图：

```bash
./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant albedo
./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --debug normal
```

albedo 图能立刻看出“左半边是不是被一个巨大的近景物体挡住了”；normal 图能
看出那半边到底是墙、树冠还是地面。只靠带阴影的 radiance 图会把“全黑阴影”
和“相机在物体内部”混在一起。

### 4. 默认的 `--cull front` 不适合 Bistro

02_shadows 的默认值是 `--cull front`（阴影 pass 剔除正面、画背面），这是为
`shadow_basic` 里封闭的立方体标定的，能有效压 acne。Bistro 有大量单面片：
树叶卡片、遮阳篷、栏杆、招牌。画背面会把遮挡体的深度存到更远的一侧，产生
**漏光**，而不是 acne。

同一个机位、同一张 2048² 阴影图，对同一张 16 spp Mitsuba 参考的误差：

| cull | PSNR | SSIM | MAE |
|---|---|---|---|
| `front`（默认） | 14.46 dB | 0.730 | 0.0648 |
| `back` | 18.08 dB | 0.817 | 0.0340 |
| `none` | **18.34 dB** | **0.822** | **0.0325** |

另外，没有贴图也意味着树叶卡片是不透明的：树冠的阴影是一整块，而不是
alpha-tested 的斑驳影子。判阴影边缘时用立面和街道，不要用树冠。

所以 Bistro 的命令统一带 `--cull none --bias 0.001`。这不是说默认值错了：
默认值对 `shadow_basic` 是对的，Bistro 只是另一种资产。把这两个数写进命令
而不是偷偷改默认值，是为了让对比仍然可复现。

## 首轮数据

1280×720，2.84M 三角形，方向光，`--cull none --bias 0.001`，Mitsuba `direct`
64 spp 作参考。性能用 `scripts/bench.sh` 跑 60 帧 × 3 次，取最好一轮的 p95：

| 阴影图 | PSNR | SSIM | MAE | p50 ms | p95 ms | 阴影内存 |
|---|---|---|---|---|---|---|
| 2048² | 18.41 dB | 0.825 | 0.0324 | 2.68 | 3.16 | 16 MiB |
| 8192² | 19.24 dB | 0.873 | 0.0276 | 3.45 | 4.00 | 256 MiB |

几个解读：

- **PSNR 只有 18–19 dB 不是导入错了。** 参考是精确光线追踪，实时侧是
  2048²/8192² 的 shadow map；主要误差在阴影边缘、细栏杆和树叶，以及实时
  G-buffer 没有抗锯齿。8192² 把 MAE 从 0.032 降到 0.028，SSIM 从 0.825 升到
  0.873，说明误差确实主要来自阴影分辨率。
- **4 倍分辨率只贵 0.84 ms。** 2.84M 三角形的 shadow pass 在 M5 上是顶点/光栅
  受限，8192² 的深度写入并没有想象中贵；贵的是 256 MiB 显存。这个 Pareto 点
  对后续 CSM/PCSS 很有参考价值。
- **单帧 `gpu time` 和 bench 的 p95 差很多**（单帧 10–14 ms，bench 3.2 ms）。
  bench 默认把 8 帧编码进同一个 command buffer 再除以 8，摊掉了提交/调度
  开销；单帧数字受调度噪声支配。报告里必须写清楚用的是哪一个。
- 实时图里阴影是**纯黑**的，因为 shading 只有直接光、没有环境项。这不是
  bug：判 visibility 时它反而更干净。想看阴影里的细节就提高曝光看 EXR，
  或者等 P2 的面积光/环境项。

## 复现

```bash
source env.sh
python3 core/02_shadows/tools/bistro_scene.py all
./scripts/build.sh --release 02_shadows

./scripts/run.sh --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
    --cull none --bias 0.001

python3 scripts/render_ref.py --scene core/02_shadows/scenes/bistro_plaza.xml \
    --spp 64 --seed 0 --out references/_smoke/bistro_plaza_64spp_seed0.exr

./scripts/bench.sh 02_shadows --tag bistro_plaza_2048 --frames 60 --repeat 3 \
    -- --scene .cache/scenes/bistro_plaza.nxscene --variant sm \
       --cull none --bias 0.001 --shadow-size 2048
```

## 还没做的

- **材质分组/贴图**：当前整场景一个 draw call、一个反照率。做 shadow 算法
  比较足够了；做材质/IBL 阶段时再说。G3D 的 zip 本来也没有贴图。
- **GPU visibility mask**：`tools/raycast_ref.py` 是 numpy 暴力遍历，2.84M
  三角形不能这么干。下一步可以用 Mitsuba 的 `ray_intersect` 批量发射主射线
  + 阴影射线，得到和实时侧同分辨率的 mask；这属于 P2/P4 的工具，不是导入的
  前置条件。
- **CSM/PCSS**：Bistro 的尺度（100 m 级别）比 `shadow_basic` 大两个数量级，
  正好用来暴露单张 ortho 阴影图的 texel 世界尺寸问题。2048² 时是 8.4 cm/texel，
  8192² 是 2.1 cm/texel；等到 CSM 时就能直接对比 cascade 分区。
