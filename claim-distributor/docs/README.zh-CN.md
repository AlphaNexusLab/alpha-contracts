# AlphaNexus ClaimDistributor

ClaimDistributor 用于 ERC20 代币的 Merkle 分发。每个实例固定绑定一个代币；发布者为每个批次分别充值，用户使用 Merkle proof 领取额度。

| 入口 | 内容 |
| --- | --- |
| [合约源码](../contracts/ClaimDistributor.sol) | 当前公开版本，采用 publisher 两步交接 |
| 第三方审计报告 | 待发布 |
| [单元测试](../test/ClaimDistributor.t.sol) | 合约行为与权限验证 |

## 角色与资金流

- `publisher`：先批准代币 allowance，再调用 `createDistribution` 充值并发布不可变 Merkle root。批次 ID 不可重复使用。
- 用户：`claim` 为自己领取并指定收款地址；`claimFor` 允许任何人提交有效证明，但款项固定转给证明中的账户。两个批量接口整体成功或整体回滚。
- `admin`：可以取消单个批次并转出其剩余额度，也可以永久停止全部分发或清退合约绑定代币的全部余额。管理员能撤回尚未领取的资金。

publisher 交接分为提名 `transferPublisher` 和接任者主动确认 `acceptPublisher`；确认前旧 publisher 继续拥有发布权限。可用 `cancelPublisherTransfer` 撤销提名。建议使用独立的 publisher 与 admin 地址，部署时明确管理员的操作政策。

## 接入边界

- 所有金额均使用代币最小单位整数，不固定为 18 位精度。充值必须足额到账；手续费、rebase 或其他改变转账金额的行为不受支持。
- `claimFor` 无需受益人授权，可能先于受益人自行领取。合约类型受益人应能管理直接转入的代币。
- `emergencyStop` 永久停止新发布与领取，没有恢复入口。停止后仍可按权限执行取消和清退。
- `emergencyWithdraw` 清退全部绑定代币；转账失败时整笔回滚，首次停止也回滚。紧急时可先独立调用 `emergencyStop`。
- `remainingAmount` 是批次账面额度，清退后可能仍保留历史数值，索引器应同时读取全局停止状态、取消状态和实际余额。
- 误转其他代币没有救援入口。放弃 admin 权限不可逆；停止后退出要求绑定代币余额为零，外部 dust 转账可能干扰退出。
- 合约没有升级入口。修改源码不会改变历史部署实例。本次公开不宣告主网部署。

## 第三方审计

当前暂无已发布的审计服务商报告。后续正式报告统一收录于 `audits/` 目录。
