# ProxyPin 流量特征优化指南

## 问题分析

当前实现存在多个容易被流量分析系统识别的特征模式，主要集中在证书签名、协议参数、网络头部等方面。

---

## 优化方案

### 1. 证书签名规范化

**当前问题：**
- `lib/network/util/crts.dart:109-121` 中证书 Subject 信息固定且具有明显标识
- OU 字段固定为 "ProxyPin"
- 所有证书有效期均为 365 天
- ST/L/O 字段使用相同值

**优化措施：**

1.1 **动态化 Subject 信息**
   - 从真实目标服务器证书复制 Subject 字段（O、OU、C、ST、L）
   - 或随机选择常见合法组织名称
   - 建议维护一个常见证书主题数据库（如：Delaware、Microsoft Corporation、Google LLC 等）

1.2 **有效期对齐**
   - 不使用固定 365 天有效期
   - 采用与目标服务器证书接近的有效期范围（180-730 天随机）
   - 或完全复制目标证书的有效期时间跨度

1.3 **序列号随机化**
   - 使用密码学安全的随机数生成器生成证书序列号
   - 避免使用递增序列号

1.4 **扩展字段对齐**
   - 复制目标证书的 X.509 扩展字段（SAN、Key Usage、Extended Key Usage）
   - 特别注意 Subject Alternative Name 的完整复制

---

### 2. TLS 指纹标准化

**当前问题：**
- `lib/network/channel/network.dart:285` 证书验证完全关闭
- `lib/network/util/tls.dart` 中 TLS 握手参数可能与标准客户端不符

**优化措施：**

2.1 **客户端 TLS 握手模拟**
   - 使用与主流浏览器相同的 Cipher Suite 顺序（Chrome/Firefox/Safari）
   - 匹配对应浏览器的 TLS 扩展顺序和内容
   - 特别注意：签名算法、支持的组、ALPN 协议列表的顺序

2.2 **服务端 TLS 响应对齐**
   - 向客户端响应时，使用目标服务器返回的 Cipher Suite
   - 复制目标服务器的 Session ID 长度特征
   - 保持 Server Hello 消息结构与真实服务器一致

2.3 **证书链完整性**
   - 如果目标服务器发送多级证书链，代理也应发送相同层级的链
   - 中间证书的 Issuer/Subject 关系应保持真实

---

### 3. HTTP 协议规范化

**当前问题：**
- `lib/network/handle/http_proxy_handle.dart` 未清理代理特征头部
- `lib/network/http/http_headers.dart` 保留了可能暴露身份的字段

**优化措施：**

3.1 **头部清理策略**
   - 移除或重写以下头部：
     - `Proxy-Connection` → 删除
     - `Proxy-Authorization` → 删除
     - `X-Forwarded-For` → 删除或仅保留客户端真实 IP
     - `X-Forwarded-Proto` → 删除
     - `Via` → 删除
     - `Forwarded` → 删除

3.2 **头部顺序保持**
   - 保持客户端原始头部的发送顺序
   - 不要重新排序或归一化头部名称大小写（除非客户端本身就是标准化的）
   - 新增头部应插入到合理位置（如 Host 之后、Cookie 之前）

3.3 **连接管理优化**
   - `Connection: keep-alive` 的处理应与真实服务器一致
   - `Transfer-Encoding` 和 `Content-Length` 不应同时出现
   - 分块传输时，chunk 大小应随机化（避免固定 8192 字节）

---

### 4. HTTP/2 参数动态化

**当前问题：**
- `lib/network/http/http_client.dart:204-227` 中 SETTINGS 帧参数固定
- `headTableSize=65536, initialWindowSize=1048896, maxHeaderListSize=262144` 成为指纹

**优化措施：**

4.1 **SETTINGS 参数模拟**
   - 使用真实浏览器的 SETTINGS 帧值：
     - Chrome: `HEADER_TABLE_SIZE=65536, ENABLE_PUSH=1, INITIAL_WINDOW_SIZE=6291456`
     - Firefox: `HEADER_TABLE_SIZE=65536, ENABLE_PUSH=0, INITIAL_WINDOW_SIZE=131072`
   - 根据 User-Agent 自动选择对应的 SETTINGS 配置

4.2 **WINDOW_UPDATE 行为对齐**
   - 窗口大小增长模式应与目标浏览器一致
   - 避免在连接建立时立即发送大量 WINDOW_UPDATE

4.3 **HPACK 压缩表管理**
   - `lib/network/http/h2/hpack/` 中的动态表大小应与 SETTINGS 声明一致
   - 压缩策略应优先使用静态表索引

---

### 5. Android VPN 模式优化

**当前问题：**
- `android/.../ProxyVpnService.kt:32` 虚拟 IP 固定为 `10.0.0.2`
- MTU 固定为 1500

**优化措施：**

5.1 **虚拟网络接口参数随机化**
   - 虚拟 IP 使用随机私有地址段：`10.x.y.z`（x,y,z 随机）
   - MTU 设置为常见值的随机选择：1280、1420、1500
   - 每次 VPN 连接时重新生成

5.2 **路由表优化**
   - 不使用全局路由 `0.0.0.0/0`，仅路由必要的目标网段
   - 保留本地网络路由不经过 VPN

5.3 **DNS 处理规范化**
   - 不修改 DNS 查询包的事务 ID
   - 保持 DNS 查询的原始标志位

---

### 6. 本地服务端点重命名

**当前问题：**
- `lib/network/handle/http_proxy_handle.dart:29` 使用 `http://proxy.pin/ssl` 作为证书下载地址

**优化措施：**

6.1 **域名通用化**
   - 将 `proxy.pin` 改为常见的本地域名：
     - `localhost.localdomain`
     - `internal.local`
     - `config.home`
   - 或使用随机生成的看似正常的域名

6.2 **端点路径规范化**
   - `/ssl` 改为常见的路径：`/cert`, `/ca.crt`, `/root-ca.pem`
   - 或完全禁用 HTTP 证书下载，仅通过应用内提供

---

### 7. 时序特征优化

**优化措施：**

7.1 **连接建立时序**
   - 模拟真实客户端的 TCP 握手时序
   - 在 SYN/ACK 后延迟 10-50ms 发送第一个应用数据
   - TLS 握手中，各消息间隔应符合真实网络延迟分布

7.2 **请求发送节奏**
   - HTTP/2 并发流的建立速度应与浏览器一致
   - 避免在瞬间发送大量请求（资源加载应有优先级）

7.3 **响应处理延迟**
   - 收到响应后不要立即转发，引入微小延迟（5-20ms）
   - 模拟客户端处理响应的时间

---

### 8. 行为模式规范化

**优化措施：**

8.1 **错误处理标准化**
   - `lib/network/handle/http_proxy_handle.dart:80-88` CONNECT 失败时不应返回 200 OK
   - 应返回真实的错误码：502 Bad Gateway、504 Gateway Timeout
   - 错误页面应模拟浏览器或目标服务器的错误格式

8.2 **缓存行为模拟**
   - 实现标准的 HTTP 缓存机制（Cache-Control、ETag、Last-Modified）
   - 缓存命中时的响应时间应快于真实请求（<5ms）

8.3 **重定向处理**
   - 自动跟随重定向时，Referer 头部应正确设置
   - 重定向链中的 Cookie 应正确传递

---

### 9. 请求重写功能约束

**当前问题：**
- `lib/network/components/request_rewrite.dart` 的修改可能产生不一致特征

**优化措施：**

9.1 **重写规则合理性检查**
   - 修改 User-Agent 时，同步修改 Sec-CH-UA 系列头部
   - 修改 Origin 时，检查 CORS 预检请求的必要性
   - 修改 Referer 时，确保 URL 路径合法性

9.2 **Body 修改完整性**
   - 修改 Body 后，自动重新计算 Content-Length
   - 如果原请求有 Content-MD5，则删除或重新计算
   - 压缩 Body（gzip）时，更新 Content-Encoding

9.3 **响应修改一致性**
   - 修改响应 Body 时，同步修改 ETag
   - 删除或更新 Content-Security-Policy 中的 nonce

---

### 10. 脚本拦截器安全性

**当前问题：**
- `lib/network/components/script_interceptor.dart` JavaScript 脚本可能引入异常模式

**优化措施：**

10.1 **脚本执行时间限制**
   - 单个脚本执行不超过 100ms，避免请求延迟异常
   - 超时脚本应直接放行原始请求

10.2 **脚本修改范围限制**
   - 禁止脚本删除关键安全头部（Strict-Transport-Security）
   - 禁止脚本添加非标准头部（X-Custom-*）

10.3 **脚本错误处理**
   - 脚本异常时应透明放行请求，不返回 500 错误
   - 记录错误但不影响正常流量

---

## 实施优先级

### 高优先级（立即实施）
1. 证书 Subject 信息动态化（方案 1.1）
2. 代理头部清理（方案 3.1）
3. 本地服务端点重命名（方案 6.1）
4. 虚拟 IP 随机化（方案 5.1）

### 中优先级（近期实施）
5. HTTP/2 SETTINGS 参数模拟（方案 4.1）
6. 证书有效期对齐（方案 1.2）
7. 错误处理标准化（方案 8.1）
8. TLS Cipher Suite 对齐（方案 2.1）

### 低优先级（持续优化）
9. 时序特征优化（方案 7）
10. 请求重写规则检查（方案 9）

---

## 验证方法

### 工具验证
- 使用 Wireshark 抓包对比真实浏览器流量与代理流量
- 使用 TLS 指纹检测工具（如 ja3、ja3s）对比指纹
- 使用 HTTP/2 指纹工具（如 akamai fingerprinting）检测特征

### 在线检测
- 访问 https://browserleaks.com/ssl
- 访问 https://www.ssllabs.com/ssltest/viewMyClient.html
- 访问 https://tls.browserleaks.com/json

### 行为验证
- 对比代理前后的请求响应时序分布
- 检查证书链完整性
- 验证 HTTP 头部顺序和大小写

---

## 配置建议

### 配置文件结构（建议新增）
```
config/
├── certificate_profiles.json    # 证书主题模板库
├── browser_fingerprints.json    # 浏览器指纹配置
├── http2_settings.json          # HTTP/2 参数配置
└── header_whitelist.json        # 允许通过的代理头部
```

### 运行时配置
- 允许用户选择模拟的浏览器类型（Chrome/Firefox/Safari/Edge）
- 提供"标准模式"和"增强兼容模式"切换
- 记录日志时标注应用的优化策略

---

## 注意事项

1. **兼容性优先**：所有优化不应破坏现有功能，特别是调试功能
2. **性能影响**：证书复制、头部解析等操作应缓存结果，避免重复计算
3. **更新策略**：浏览器指纹库需定期更新（每季度），跟随主流浏览器版本
4. **降级机制**：如果目标服务器证书解析失败，回退到通用证书生成策略
5. **测试覆盖**：每项优化都应有对应的自动化测试用例

---

## 效果评估

实施上述优化后，预期达到以下效果：

1. **证书层面**：证书指纹与常规合法证书无显著差异
2. **协议层面**：TLS 和 HTTP/2 指纹与目标浏览器一致
3. **头部层面**：请求头部不包含任何代理特征字段
4. **行为层面**：连接时序和请求模式符合真实客户端分布
5. **检测率降低**：在常见流量分析系统中的识别率降低 90% 以上

---

## 更新记录

- **2025-11-08**：初始版本，基于代码审计结果编制
