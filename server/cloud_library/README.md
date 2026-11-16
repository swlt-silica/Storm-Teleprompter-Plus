# 私人云稿库

Python 3.10+ 标准库服务，使用 SQLite 持久保存脚本。它只提供稿库同步和 Markdown 上传，不处理手机麦克风，也不控制设备播放。设备下载到本机后自行离线提词，原来的局域网远程提词不受影响。

## 固定 Markdown 格式

```md
---
script_id: "TC-001"
---

## 正文

这里写实际要朗读的台词。
同一段的换行会保留。

这里是另一段台词。

## 备注

这里的分镜和拍摄说明不会被导入。
```

- 信息区只接受一个 `script_id` 字段，不是通用 YAML 解析器，不支持其他字段、注释、转义或多行值。
- 编号由 1–64 位 ASCII 字母、数字、点、下划线或短横线组成，以字母或数字开头；用引号可直观看清 `001` 等编号。数字前导零保留，大小写敏感。
- 稿件标题等于脚本编号。同一编号再次上传时更新原稿，不新增副本；正文未变化时不增加修订号。
- 正文是二级标题 `## 正文` 后，到下一个一级或二级标题之前的文本。`## 备注` 等后续内容忽略。正文不得为空。
- 正文请直接写纯台词，不要加 Markdown 加粗、列表、链接、代码、HTML 或分镜说明；服务不会自动去除这些标记，也不会执行其中内容。HTML 输出会转义文字，按每行一个段落排版，与客户端一致。
- 上传需 UTF-8，最大 1 MiB；单篇正文最多 50000 个 UTF-16 单位（一个常见汉字为一单位，emoji 常为两单位）。库最多 1000 篇；正文总计 8000000 单位，排版 HTML 总计 24000000 单位，完整 JSON 响应最多 32 MiB。超限或格式错误先拒绝，事务不写入。

## 给整理脚本的 AI 的说明

可将以下规则加入整理任务，不要把令牌交给模型或写入 Markdown：

> 将输入整理为 `example.md` 格式。把脚本编号逐字填入唯一的 `script_id`，保留前导零，不使用标题或文件名猜测新编号。`## 正文` 中只放适合直接朗读的正文，保留自然分段，不写 Markdown 加粗、项目符号、链接、代码或 HTML。分镜、备注和修改建议放在后面的 `## 备注`。一个文件只放一个脚本。编号不明确时先确认，不擅自覆盖另一个编号。

AI 输出文档后，运行本目录上传工具即可。服务没有内置 AI 调用，不会把原文发送到其他服务。

若使用支持自定义 Actions 的 GPT，可将同目录 `openapi.json` 导入 Actions 定义，并在该 GPT 的鉴权设置中选择 API Key / Bearer，填入上传令牌。真实令牌只填鉴权配置，不放进普通提示词、Markdown 或接口定义。普通聊天窗口不会因输出 Markdown 自动获得上传能力；未配置 Action 时使用下方 CLI 上传。

## API

请求使用 `Authorization: Bearer <令牌>`。读令牌和上传令牌必须不同，均为至少 32 位随机字符串；读令牌只能下载，上传令牌可下载及更新稿件。禁止在 URL 查询参数中携带凭据。

| 接口 | 权限 | 结果 |
| --- | --- | --- |
| `GET /healthz` | 无 | 仅 `{"status":"ok"}` |
| `GET /api/v1/library` | 读或上传令牌 | 完整稿库快照 |
| `POST /api/v1/scripts/import-markdown` | 上传令牌 | 新建返回 201，更新或未变化返回 200 |

上传 Content-Type 可为 `text/markdown; charset=utf-8`，直接发送 Markdown；也可为 `application/json`，发送唯一字符串字段 `{"markdown":"完整 Markdown 文本"}`，适合 GPT Actions。JSON 不接受其他字段或重复键。两种方式均使用明确 Content-Length，整个请求最大 1 MiB，服务不接受分块上传。返回 `{"created":true或false,"script":{...}}`。

快照格式：

```json
{
  "format": "storm-cloud-library",
  "version": 1,
  "libraryId": "持久化的 UUID",
  "revision": 1,
  "scripts": [{
    "scriptId": "TC-001",
    "title": "TC-001",
    "body": "实际台词",
    "content": "<p>实际台词</p>",
    "createdAt": "2026-11-16T00:00:00.000Z",
    "updatedAt": "2026-11-16T00:00:00.000Z",
    "revision": 1
  }]
}
```

编号排序稳定。`libraryId` 在同一个数据库中保持不变，`revision` 仅在正文实际变化时增加。此版本没有删除、清空或全库恢复 API。

## 运行

仅监听 `127.0.0.1`，默认 18431 端口。公网访问由现有 HTTPS 反向代理转发；若部署在 `/teleprompter/` 前缀，代理应将该前缀剥离再转发给本服务。

用权限受限的文件分别保存读令牌及上传令牌，配置：

```sh
export CLOUD_LIBRARY_DATA_DIR=/你的持久化目录
export CLOUD_LIBRARY_PORT=18431
export CLOUD_LIBRARY_READ_TOKEN_FILE=/私密目录/read-token
export CLOUD_LIBRARY_UPLOAD_TOKEN_FILE=/私密目录/upload-token
python3 app.py
```

也支持 `CLOUD_LIBRARY_READ_TOKEN` / `CLOUD_LIBRARY_UPLOAD_TOKEN` 环境变量，文件入口优先。不要将实际值加入命令行、仓库或公开日志。服务不会记录请求路径、查询参数、令牌或正文。使用 SQLite WAL 与事务，数据目录权限为 700，数据库为 600；需要备份时保存完整 SQLite 数据库及 WAL 一致快照，不只复制有写入活动的主文件。

## 上传工具

```sh
# 无需令牌，先检查全部输入。校验失败时不会发送任何请求。
python3 upload.py --directory /脚本文档目录 --dry-run

# 单稿上传；地址可包含部署前缀。
python3 upload.py --url https://你的域名/teleprompter \
  --token-file /私密目录/upload-token --file /脚本文档目录/TC-001.md

# 批量上传前也会完整校验所有文件及本批重复编号。
python3 upload.py --url https://你的域名/teleprompter \
  --token-file /私密目录/upload-token --directory /脚本文档目录
```

工具拒绝公网 HTTP 和重定向，防止令牌被转交其他主机。只有本机开发可使用 `http://127.0.0.1:18431`。

批量上传按文件逐个事务提交，不是整批原子事务。如果中途失败，报告 `partialSuccess`、成功数量及逐稿结果，后续文件不上传。成功稿件已保存，修复后可整批重试；同编号同正文不会重复新增。

## 验证

```sh
python3 -m unittest discover -s tests -v
python3 upload.py --file example.md --dry-run
```

测试使用临时数据库和真实本机 HTTP 请求，不接触部署库或用户稿件。
