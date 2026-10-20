# 01 先把坐标、朝向和深度钉死，再谈阴影

> 这一篇记录 P0 的校准过程。校准不是「跑通」的附属品：阴影算法的一半 bug
> 看起来像算法问题，实际是相机、朝向、深度或光照单位的错位。先把这些量对齐，
> 后面每一张阴影图才有可解释性。

---

## 1. 校准顺序：albedo → lit → 可见性

1. **albedo**：关闭光照，只输出 G-buffer 的反照率，和 Mitsuba 的 `albedo:albedo`
   AOV 比。它检查相机、投影、几何、分辨率、左右/上下是否一致。任何镜像或半像素
   偏移都会在这里暴露，而不会伪装成阴影问题。
2. **lit**：打开方向光，强制可见性为 1，和 Mitsuba `direct` 的无遮挡像素比。
   它检查 BRDF、光单位、法线朝向。参照图用 ray-cast 可见性筛出「参考确实是可见」的
   像素，再腐蚀掉轮廓边缘。
3. **可见性**：只有前两步通过，才比较 shadow map 的 mask 和 ray-cast 真值。

P0 实测：

| 检查 | 指标 | 结果 |
|---|---|---|
| albedo | 轮廓 IoU | 0.999324 |
| albedo | PSNR / SSIM | 48.09 dB / 0.9951 |
| albedo | 内部 MAE | 1.33e-4 |
| lit | 无遮挡区 MAE（体素） | 2.7e-8（浮点精度） |
| lit | ROI MAE（含边缘） | 3.98e-4 |
| lit | PSNR / SSIM | 45.29 dB / 0.9908 |
| sm | mask IoU（768²） | 0.999651 |
| sm | mask IoU（1080p） | 0.999760 |
| sm | acne / peter-pan | 0.0031% / 0.0208% |

`lit` 的 ROI MAE 3.98e-4 几乎全来自边缘：Mitsuba 的 64 spp box filter 在轮廓/阴影边界
做超采样，而实时图是 1 spp 硬边。体素内的 2.7e-8 才说明光照单位和 BRDF 是对的。

albedo 的最大误差 0.2 出现在方块和地面的**共面接触**处：Mitsuba 的 AOV 在那个像素上
可能采到方块底面，而实时 G-buffer 背面剔除后看到的是地面，二者反照率不同（0.65 vs 0.55）。
这是接触面的光栅化平局，不是相机/几何错位；离开材质边界后误差是浮点精度。
如果要让这个指标也干净，可以把方块抬高 5 mm（接触阴影看起来不变），或者按材质边界
腐蚀 ROI；P3 的 peter-panning 场景会单独处理接触。

---

## 2. 约定

| 项 | 约定 |
|---|---|
| 世界 | 右手系、Y up、线性 RGB；顶点已烘焙到世界空间 |
| 相机 | 由 `origin / right / up / forward` 描述；看向 -Z |
| 投影 | 右手系，clip-space z ∈ [0,1]（Metal 约定，不是 OpenGL 的 [-1,1]） |
| 图像 | 像素 (0,0) 在左上；NDC y 向上，viewport 翻转 y |
| 深度 | G-buffer 的 normal target 的 alpha 存光栅化后的 NDC z；visibility 用它重建世界坐标 |
| shadow map | 存光空间的 NDC z；采样 uv 的 y 要再翻一次（render pass 的 viewport 翻过一次） |
| 方向光 | Mitsuba 的 `direction` 是**光的传播方向**；着色用 `-direction` |
| 三角形 | Mitsuba 的正面是 CCW；Metal 里显式 `MTLWindingCounterClockwise` |

**G-buffer 的 normal target = (世界法线, NDC 深度)。** 这样 visibility 的 compute
不需要读 depth attachment，调试视图也看到同一个深度值。这是一个小设计，但省掉了
「depth2d 能不能在 compute 里 read」的一整类平台问题。

---

## 3. 踩过的坑（都是实测，不是猜测）

### 3.1 Mitsuba 的 transform 按列出顺序应用

`<scale/><translate/>` 表示先缩放再平移；反过来写会把平移也缩放掉。
第一次写场景时写成了 `<translate/><scale/>`，结果每个遮挡物都朝原点缩了一截，
导出的第一个 mesh 的中心是 `(scale * translate)`，而我以为它是 `translate`。
现在场景文件里有注释，导出器和笔记里也都记着。

**推论**：场景里看到「物体位置不对」时，先检查 transform 顺序，再怀疑相机。

### 3.2 `.nxscene` 的 `tri` 行是「先 3 个位置，后 3 个法线」

不是交错的 `p0 n0 p1 n1 p2 n2`。解析器最初按交错读，位置被法线污染，
渲染结果是一团尖刺。导出器的写法和 C++ parser 的读法现在逐字段对齐，
笔记和 README 都写了这条。

### 3.3 相机基不能直接用 `sensor.to_world`

Mitsuba 的 sensor `to_world` 局部轴不是 film 的左右/前向。导出器用
`sensor.sample_ray()` 在 film UV (0.5,0.5)、(1,0.5)、(0.5,0) 采三条射线，
反推 `origin / right / up / forward` 和 `fov_x/fov_y`。这是与实现无关的做法，
换任何相机变换都不会漂。

顺带两个小事实：`x_fov` 的 traverse 值已经是**度**（不要再乘 `180/π`）；
`sample_ray` 返回的射线起点在近平面，而不是相机原点，所以 origin 从
`to_world` 的平移取。

### 3.4 Winding 和单面几何

Mitsuba 的三角形正面是 CCW。Metal 的 `setFrontFacingWinding` 必须显式设置；
一开始设成 clockwise，结果单面的地面被剔掉、所有方块看到的是背面。
判断方法不是猜，而是看 albedo AOV：地面消失、方块轮廓还在，就说明正面定义反了。
校准通过后改成 `MTLWindingCounterClockwise`。

### 3.5 光方向是传播方向

Mitsuba 的 directional `direction=(0,0,-1)` 会照亮法线 +Z 的平面，radiance = albedo/π。
所以着色是 `dot(n, -direction)`。这个符号错一次，整张图会从「有阴影」变成
「只有背面发黑」，但指标仍然能算出数字——所以校准要先做。

### 3.6 其他

- `sphere` 在 Mitsuba 里是解析形状，不是 mesh；导出器拒绝它。曲面请用 OBJ。
- `rectangle`/`cube` 是 `mi.Mesh`，`vertex_position(i)` 已经是世界空间。
- AOV 语法是 `aovs="albedo:albedo"`；`aov` 积分器需要 `name:type`。
- Mitsuba 的 `write_bitmap` 是异步的；所有写图走 `scripts/nx_io.py`。
- 场景里显式写 `near_clip`/`far_clip`；默认 0.01/10000 的深度精度不适合 G-buffer。

---

## 4. 阴影侧的实现细节

- **方向光拟合**：取场景 AABB 的中心，沿光方向退到包围球外，`look_at` 建光视图；
  把 8 个角点变换到光空间，取 x/y/z 的 min/max，加 padding，再把正交框 snap 到
  texel 的整数倍（为以后相机移动时的稳定性打基础）。
- **shadow pass 剔除**：默认 `cull front`（渲染背面）。地面是单面几何，会被剔除，
  所以地面不会在 shadow map 里产生自阴影；方块存的是背面深度，接收面比较时
  「接收面 <= 背面深度 + bias」得到正确遮挡。thin panel 同理。
- **bias**：默认比较 bias 1e-3（shadow-map NDC z），光栅器 depth/slope bias 为 0。
  `--bias=0` 会立刻看到 acne；P3 会把 bias 扫描和 peter-panning 一起量。
- **采样约定**：`receiver = light_ndc.z`，`stored = shadow_map.sample(uv)`，
  比较 `receiver <= stored + bias`；uv 的 y 在 compute 里再翻一次。
- **per-pass 计时**：G-buffer/阴影/可见性/着色各用一个 command buffer，
  所以各 pass 之和是帧时间的上界；头条帧时间用「一个 command buffer 装整帧」。
  1080p 的实测分解（p50）：gbuffer 0.08、shadow 0.03、visibility 0.09、shading 0.14 ms，
  合计 0.34 ms；单 CB 帧 0.32 ms。

---

## 5. 在相信任何阴影数字之前，检查这 6 条

1. albedo AOV 的轮廓 IoU（目标 ≥ 0.995）。
2. lit 的无遮挡体素误差（目标 < 0.1%；我们的体素是浮点精度）。
3. sm 的 mask 与独立 ray-cast 的 IoU（目标 ≥ 0.99；我们 0.9997）。
4. 图像里同时存在 0 和 1 的可见性，且没有 NaN。
5. 固定 seed、参数进文件名、Release 构建、计时口径一致。
6. 报告里记录 bias、shadow map 尺寸、filter taps、分辨率；不允许为了好看隐藏参数。

---

## 6. 代码导航

- `src/math.h`：列主序矩阵、`view_from_basis`、`perspective`（z∈[0,1]）、`ortho`、`inverse`。
- `src/scene.cpp`：`.nxscene` 解析；`tri` 行的位置/法线布局；相机基校验。
- `src/renderer.mm`：G-buffer、深度专用 shadow pass、可见性 compute、共享着色、
  单 CB/逐 pass 计时、显存统计。
- `shaders/gbuffer.metal`：normal target 的 alpha 存 `position.z`。
- `shaders/visibility.metal`：世界坐标重建、光空间投影、uv y 翻转、box PCF。
- `src/main.mm`：CLI、自检、bench、EXR。

下一篇：`02_pcf.md` —— PCF 把「比较」变成「平均」，以及它没解决什么。
