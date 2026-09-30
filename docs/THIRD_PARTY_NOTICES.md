# 第三方组件声明(THIRD_PARTY NOTICES)

## chmlib 0.40a

- 来源:上游 `chmlib-0.40a`(orig tarball,取自 Ubuntu archive pool,与 jedsoft.org 官方发布同源)
- 用途:CHM(ITSF)容器解析与 LZX 解压,vendored 于 `Sources/CChmlib/`
- 许可:**GNU LGPL 2.1**,全文见 `Sources/CChmlib/COPYING.LGPL`
- 出处:http://www.jedsoft.org/chmlib/(作者 Jed Wing)

### 本地安全补丁

上游 2009 年后无发布;以下修改相对 orig tarball,与 Debian(`0.40a-9`)/
SumatraPDF(commit `0817994`)对 CVE-2025-48172 的修复方向一致:

- `chm_lib.c` `_unmarshal_lzxc_reset_table`:拒绝 `block_len` 为 0 或超过
  2MB(LZX 窗口上限)的 reset table。原代码将其按 `(unsigned int)` 截断后
  参与定长 malloc,构造的 ≥2³² 值会使 `block_len + 6144` 回绕、缓冲区
  过小,导致 `_chm_fetch_bytes` 堆溢出(打开恶意 CHM 即触发)。
- `chm_lib.c` `_chm_decompress_block`:三处 malloc 改用 `size_t` 计算
  (纵深防御)。

Chimera 本体以 MIT 发布(见仓库根 LICENSE);vendored 的 chmlib 源码保持
LGPL-2.1 原样分发并随仓库提供源码,符合 LGPL 对源码随发的合规要求。
