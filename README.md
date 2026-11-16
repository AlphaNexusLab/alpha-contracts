# AlphaNexus Smart Contracts

Official public source code, product documentation, and third-party audit reports for AlphaNexus smart contracts, maintained by **AlphaNexusLab**.

AlphaNexus 官方合约公开库，向服务商及用户提供源码、产品文档和第三方审计报告。

| Product / 产品 | Description / 用途 | Documentation / 文档 | Source / 源码 | Audit reports / 审计报告 |
| --- | --- | --- | --- | --- |
| ClaimDistributor | Independently funded ERC20 Merkle distributions / 独立充值的 ERC20 Merkle 分发 | [English](claim-distributor/docs/README.md) · [中文](claim-distributor/docs/README.zh-CN.md) | [ClaimDistributor.sol](claim-distributor/contracts/ClaimDistributor.sol) | Pending / 待发布 |

Third-party audit reports will be added to each product's `audits/` directory when published. No third-party audit report has been published for ClaimDistributor yet.

`audits/` 仅用于存放审计服务商提供的报告。ClaimDistributor 目前暂无已发布的第三方审计报告。

## Build and unit tests

Requirements: Node.js 22 or later, npm, and Foundry (`forge`).

```bash
npm ci
npm run build
npm test
```

Build settings and dependency versions are recorded in [foundry.toml](foundry.toml) and [package-lock.json](package-lock.json).

## Repository layout

```text
claim-distributor/
├── contracts/   # Contract source
├── docs/        # Product documentation
├── audits/      # Third-party audit reports (pending)
└── test/        # Unit tests
```

License: [MIT](LICENSE).
