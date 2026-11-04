# CPU vs CPU+NPU: PPA on a 16x16x16 INT8 GEMM

Clock 0.75 ns (1.333 GHz) for both tops; 4096 MACs = 8192 ops. Power: Innovus `report_power` at TT 25 C with switching activity (SAIF) from the post-P&R gate-level simulation with fast-corner SDF, over the start-to-end window of the benchmark; macros reported from their own databases and added. Area: die area of each top.

| Configuration | Cycles | Latency (us) | Power (mW) | Area (mm2) | GOPS | GOPS/W | GOPS/mm2 | Energy (nJ) | pJ/MAC | EDP (nJ*us) | Speedup | Energy gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CPU only (ibex_cfet_top), software GEMM | 18,000 | 13.50 | 8.80 | 0.0049 | 0.61 | 69 | 124 | 118.8 | 29.01 | 1604.28 | 1.00x | 1.00x |
| CPU+NPU (ibex_npu_top), NPU GEMM end to end | 4,750 | 3.56 | 13.33 | 0.0116 | 2.30 | 173 | 198 | 47.5 | 11.59 | 169.18 | 3.79x | 2.50x |
| CPU+NPU, DMA kernel only (A/B already in SRAM0; whole-run average power) | 2,040 | 1.53 | 13.33 | 0.0116 | 5.35 | 402 | 461 | 20.4 | 4.98 | 31.20 | 8.82x | 5.83x |
| CPU+NPU (ibex_npu_top), software GEMM (NPU idle) | 18,000 | 13.50 | 14.33 | 0.0116 | 0.61 | 42 | 52 | 193.4 | 47.23 | 2611.52 | 1.00x | 0.61x |

NPU run breakdown (cycles): copy A,B in by the CPU 899, DMA tiled GEMM 2040 (CPU polling 2053), copy C out by the CPU 1798.
Array peak: 8x8 MACs/cycle = 171 GOPS; achieved in the DMA kernel 2.01 MACs/cycle (3.1 % of peak): the design is data-movement bound (32-bit word copies per 8x8x8 tile, results read back one word at a time).

Power breakdown (mW): {"npu_gemm": {"top": 8.68254335, "acc": 2.73133972, "sram0": 0.9252153, "sram1": 0.9912123}, "sw_gemm_on_npu_top": {"top": 10.00147975, "acc": 2.5299077, "sram0": 0.89897471, "sram1": 0.8989747}, "cpu_only": 8.80262838}
