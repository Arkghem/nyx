# 00 阴影算法地图：从「深度比较」到「遮挡表示」

> 状态：P0/P1 已落地（SM / PCF / 真值 / 指标 / Pareto）。这份笔记是整条路线的索引，
> 具体数字见 `01_shadow_map_conventions.md` 和 `02_pcf.md`。

---

## 1. 这个实验到底在比较什么

所有阴影算法都在回答同一个问题：对接收面上的一个点 \(x\)，沿光源方向看过去，
有多少光被挡住。把可见性记作 \(V(x,\omega_l)\in[0,1]\)，直接光照就是

```
L_o(x, \omega_o) = albedo/π · E(x) · V(x, \omega_l)
```

这里的 \(E(x)\) 是未遮挡的辐照度。**本项目把 \(V\) 单独拎出来当作被求解的量**：
G-buffer 只算一次相机可见的点和法线；每个阴影算法只负责写一张 R32F 的可见性图；
着色 pass 共享。这样比较的是「谁把 V 算得更准 / 更快」，而不是「谁的光照模型不一样」。

> 一个重要后果：如果只比较最终辐射图，光照单位、相机、bias 的差异会混进来。
> 所以除了辐射对比，还要有独立的可见性真值（ray cast）和只针对 V 的指标。

---

## 2. 三条技术轴

任何一个阴影方案都可以拆成四个问题：

1. **分辨率分配（partition）**：阴影数据放在光空间的哪里？
   - 单张正交/透视深度图、级联（CSM）、裁剪图（clipmap）、虚拟页表（virtual SM）、
     世界空间体素网格、模板体积（shadow volume）、直接光追。
2. **遮挡表示（storage）**：每个 texel / voxel 存什么？
   - 深度、二阶矩、四阶矩、透射率序列（AVSM）、体素占据、几何/模板。
3. **过滤（filter）**：怎么从表示重建 V？
   - 最近邻、PCF、PCSS、Chebyshev、指数、矩重建、透射率查询、DDA 射线步进、模板测试。
4. **接收面偏移（bias）**：怎么避免 acne，同时不把阴影拉离接触点？
   - 常数 bias、slope-scaled bias、normal offset、receiver-plane bias、cull 模式。

这四件事正交。`--pipeline` 的组件语法就是按这个拆的；命名预设只是常用组合的快捷方式。

---

## 3. 工业线：每一代都在修上一代的哪个洞

| 年代 | 技术 | 修复了什么 | 新代价 | 今天 |
|---|---|---|---|---|
| 1978 | shadow map（Williams） | 任意几何的硬阴影 | bias/acne、分辨率走样 | 所有阴影系统的基础 |
| 1987 | PCF（Reeves 等） | 阴影边缘锯齿 | taps/带宽；不产生真实半影 | 几乎所有实时引擎 |
| 2002 | PSM（Stamminger & Drettakis） | 透视走样 | 后投影奇异、场景依赖 | 基本淘汰，教学价值高 |
| 2005 | PCSS（Fernando） | 接触硬化/半影 | blocker search 的噪声和成本 | 局部使用，离线常见 |
| 2006 | VSM（Donnelly & Lauritzen） | 可滤波的软阴影 | 漏光、偏置 | 局部使用 |
| 2007 | CSM（Engel 等） | 大场景的分辨率分配 | 级联接缝/闪烁 | 太阳光标配 |
| 2008 | ESM / convolution SM | 可滤波 | 精度、漏光 | 研究与局部 |
| 2010 | AVSM（Salvi 等） | 薄遮挡/透射率 | 显存、原子竞争 | 头发、离线 |
| 2015 | MSM（Peters & Klein） | 减少矩方法的漏光 | 四阶矩、精度 | 研究与局部 |
| 2021+ | virtual SM（UE5） | 分辨率与内存解耦 | 页表、实现复杂度 | UE5 |
| 现在 | 硬件光追阴影 | 精确、无 bias | 射线预算、降噪 | 现代 3A 的重要选项 |

**工业线的主线是「固定毫秒预算下，把有限的分辨率分配到最需要的地方」。**
阴影贴图不是「一把分辨率」，而是一份预算：级联、页表、裁剪图都是在分配这份预算。

---

## 4. 学术线：遮挡数据结构的演进

- **精确可见性**：shadow volume（Crow 1977；depth-fail 的 Heidmann/Carmack）、
  光线/路径追踪。精确的硬阴影，但 fill/几何或射线预算的代价高，且不天然支持软阴影。
- **可滤波表示**：VSM、ESM、MSM、AVSM、Fourier opacity maps。
  共同目标是让「过滤」发生在表示上而不是在二值比较上。代价是表示误差
  （漏光、偏置、矩的条件数）。
- **自适应/页表**：Adaptive Shadow Maps、Resolution-Matched Shadow Maps、
  Sample Distribution Shadow Maps、UE5 virtual SM。共同目标是让分辨率跟着需要走。
- **体素/占据**：voxel cone tracing、distance field shadows、体素阴影。
  把遮挡搬到 3D 结构里，换软阴影和半透明，代价是显存/步进/泄漏。

学术线和工业线在 CSM、PCSS 交汇；但论文里的「更好」通常有前提：特定场景、
特定分辨率、特定 bias。这个实验的一个固定任务就是**把前提和代价一起量出来**。

---

## 5. 本实验的矩阵（P0–P7）

| 阶段 | 内容 | 关键问题 | 状态 |
|---|---|---|---|
| P0 | 校准、G-buffer、方向光 shadow map、SM | 相机/光照/深度/朝向对齐了吗 | 完成 |
| P1 | PCF、ray-cast 真值、compare/shadow_metrics、Pareto | PCF 修了什么、代价多少 | 完成 |
| P2 | 面积光、PCSS、VSM/EVSM/MSM、漏光场景 | 半影/可滤波表示的代价 | 下一步 |
| P3 | bias 扫描、acne/peter-panning/self-shadowing | 一个 bias 取舍的三张脸 | 计划 |
| P4 | CSM、PSM、分辨率/级联缩放 | 预算怎么分；PSM 为什么输 | 计划 |
| P5 | shadow volumes、z-pass/z-fail、fill 成本 | 精确硬阴影的代价 | 计划 |
| P6 | virtual SM、voxel、AVSM、冷/热缓存 | 分辨率/内存/遮挡表示的极限 | 计划 |
| P7 | 汇总、Pareto、引擎级验证（Forge 就绪后） | 到底该 ship 哪个 | 计划 |

这个顺序不是按年代，而是按**依赖和可复现性**：先把单张深度图和真值钉死，
再往软阴影、级联、体积、页表上叠。

---

## 6. 命名撞车（很重要）

- **VSM**：Variance Shadow Map（2006）和 Virtual Shadow Map（UE5，2021+）都叫 VSM。
  本实验里 `vsm` 只指 Variance；virtual shadow map 一律写 `virtual_sm`。
- **CSM**：Cascaded Shadow Maps 和 Convolution Shadow Maps 都缩写 CSM。
  代码里用 `csm` 指级联，卷积阴影写 `convolution_sm`。
- **PSM**：本实验指 Perspective Shadow Maps；不要和 PCF/PCSS 混。
- **PCF** 的硬件版本（2×2 comparison sampler）和手动 box 版本不是一回事，
  笔记和报告里要分开写。

---

## 7. 阅读清单（先记线索，写作时逐条核对）

- 教材：*Real-Time Rendering* 4th ed. Ch.7；Eisemann 等 *Real-Time Shadows*；
  PBRT 的光源采样和可见性章节。
- 硬阴影/PCF：Williams 1978；Reeves, Salesin, Cook 1987。
- 透视阴影图：Stamminger & Drettakis 2002；Wimmer 等 2004（LiSPSM）；
  Martin & Tan 2004（TSM）。
- 软阴影/可滤波：Fernando 2005（PCSS）；Donnelly & Lauritzen 2006（VSM）；
  Annen 等 2007/2008（convolution/ESM）；Peters & Klein 2015（MSM）。
- 级联/自适应：Engel 2007（CSM）；Lefohn 等 2007；Lauritzen 2011（SDSM）。
- 体积/透射率：Lokovic & Veach 2000（deep shadow maps）；
  Salvi 等 2010（AVSM）；Jansen & Bavoil 的 Fourier opacity maps。
- 体素：Crassin 等 2011（VCT）；UE5 的 distance field shadows 文档。
- 虚拟阴影：UE5 Virtual Shadow Maps 文档；其研究前身见 Adaptive Shadow Maps、
  Resolution-Matched Shadow Maps、SDSM。
- 过时但必读：Crow 1977；Heidmann 1991（depth-fail）。

> 引用时核对标题/年份/venue，不凭记忆写。论文里的图通常默认了一个 bias、
> 一个分辨率和一个场景；我们的任务是把这些默认值显式化。

---

## 8. 判卷口径：为什么必须有 Pareto

一个算法「更好」至少有三个不同含义：

1. **同成本下画质更高**（Pareto 的纵轴）；
2. **同画质下成本更低**（Pareto 的横轴）；
3. **同场景下更不容易出伪影**（acne/peter-panning/漏光/闪烁，另一组轴）。

所以报告不是一张排名表，而是：同一场景、同一相机、同一光源、同一分辨率下，
**p95 GPU/CPU ms vs 画质指标**，再标出 16.6/8.3 ms 预算线。没有预算线的排名会
诱导人把「最贵」当成「最好」。

P1 已经给了一个很好的反例：在 256² shadow map 上，PCF 把二值 mask IoU 从
0.9963 提到 0.9973（更少的 acne/硬边），但 MAME 从 0.00366 涨到 0.00854
（把锯齿换成了模糊）。**同一组数据，指标选 IoU 还是选 MAME，结论相反。**
PCF 的「正确」参照是面积光软阴影，不是硬 mask；这就是 P2 要换场景/参照的原因。

---

## 9. 当前状态与下一步

- 已完成：P0/P1；SM/PCF；albedo/lit 校准；ray-cast 真值；compare/shadow_metrics；
  1080p Pareto（3 种 filter × 3 种 shadow map 尺寸）。
- 已知边界：场景只有 50 个三角形，1080p 下总帧时间 0.32–0.43 ms，
  shadow map 尺寸在这个量级几乎免费，PCF 的 tap 成本是唯一可测差异。
  **这不是游戏帧率**，是算法级成本；引擎级数字要等 Forge 移植。
- 下一步：P2 面积光 + PCSS + VSM/EVSM/MSM；用软参考重做 filter 的质量判卷；
  再往 CSM/PSM、shadow volume、virtual SM/voxel/AVSM 推进。
