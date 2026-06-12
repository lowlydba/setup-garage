# setup-garage

> GitHub Action that starts a dockerized [Garage](https://garagehq.deuxfleurs.fr/) S3 service for testing against a real S3 API in CI.

[![License](https://img.shields.io/github/license/lowlydba/setup-garage.svg)](LICENSE)
[![CI](https://github.com/lowlydba/setup-garage/actions/workflows/ci.yml/badge.svg)](https://github.com/lowlydba/setup-garage/actions/workflows/ci.yml)

## Contents

- [Motivation](#motivation)
- [Tutorial: get started](#tutorial-get-started)
- [How-to guides](#how-to-guides)
  - [Use with custom credentials](#use-with-custom-credentials)
  - [Opt out of AWS env var injection](#opt-out-of-aws-env-var-injection)
- [Reference](#reference)
  - [Inputs](#inputs)
  - [Outputs](#outputs)
  - [Compatibility](#compatibility)

## Motivation

Testing S3 integrations in CI has become harder. MinIO relicensed from Apache 2.0 to AGPL v3 in 2021, then removed its gateway mode in 2022, which was the common approach for running a local S3 target. LocalStack filled that gap, but as of 2026 requires a login and an auth token to pull even its Community image.

setup-garage uses [Garage](https://garagehq.deuxfleurs.fr/), a lightweight, single-binary, S3-compatible object store. Its images are freely pullable with no account required. The image is small (around 25 MB compressed), so the cold pull adds only a few seconds to a job and there is no need to cache it. It exposes a real S3 API, so tests that pass locally will behave the same way in CI.

The action is published with [immutable releases and tags](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#about-release-immutability), so a version you pin today will still resolve to the same code tomorrow.

## Tutorial: get started

Add the action to any Linux CI job. No configuration required.

```yaml
steps:
  - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3

  - uses: lowlydba/setup-garage@0123456789abcdef0123456789abcdef01234567 # v1.0.0

  # AWS_* env vars are already set, just use S3
  - run: |
      echo "hello" > file.txt
      aws s3 cp file.txt s3://garage/file.txt
      aws s3 cp s3://garage/file.txt downloaded.txt
```

Credentials and a default bucket named `garage` are generated automatically. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, and `AWS_DEFAULT_REGION` are exported so the aws cli, SDKs, and tools like Terraform pick them up without any extra configuration. Pin to the commit SHA of a [tagged release](https://github.com/lowlydba/setup-garage/releases); the `# vX.Y.Z` comment is just for readability.

## How-to guides

### Use with custom credentials

Provide your own access key and secret to get predictable, reproducible values across test runs:

```yaml
- uses: lowlydba/setup-garage@0123456789abcdef0123456789abcdef01234567 # v1.0.0
  with:
    bucket: my-test-bucket
    access-key-id: GK31c5f2dab2a46c2a3b2653f3
    secret-access-key: ${{ secrets.GARAGE_SECRET }}
    region: us-test-1
    s3-port: "9000"
```

Access key IDs must start with `GK`.

### Opt out of AWS env var injection

If the job also connects to real AWS, set `set-aws-env: "false"` to avoid overwriting credentials, then pass the outputs explicitly:

```yaml
- uses: lowlydba/setup-garage@0123456789abcdef0123456789abcdef01234567 # v1.0.0
  id: garage
  with:
    set-aws-env: "false"

- run: aws s3 ls "s3://${{ steps.garage.outputs.bucket }}"
  env:
    AWS_ENDPOINT_URL: ${{ steps.garage.outputs.s3-endpoint }}
    AWS_REGION: ${{ steps.garage.outputs.region }}
    AWS_ACCESS_KEY_ID: ${{ steps.garage.outputs.access-key-id }}
    AWS_SECRET_ACCESS_KEY: ${{ steps.garage.outputs.secret-access-key }}
```

## Reference

### Inputs

| Input               | Default  | Description |
| ------------------- | -------- | ----------- |
| `garage-version`    | `v2.3.0` | Garage container image tag. `v2.3.0` or newer required. |
| `bucket`            | `garage` | Name of the default bucket to create. |
| `access-key-id`     | _(auto)_ | S3 access key ID. Auto-generated when empty. Must start with `GK`. |
| `secret-access-key` | _(auto)_ | S3 secret access key. Auto-generated when empty. |
| `region`            | `garage-east-1` | S3 region name reported by Garage. |
| `s3-port`           | `3900`   | Host port to expose the S3 API on. |
| `container-name`    | `garage` | Name for the Garage docker container. |
| `set-aws-env`       | `true`   | Export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, and `AWS_DEFAULT_REGION` for later steps. Set to `false` if the job also uses real AWS credentials. |

### Outputs

| Output              | Example                 | Description |
| ------------------- | ----------------------- | ----------- |
| `s3-endpoint`       | `http://localhost:3900` | S3 API endpoint URL. |
| `region`            | `garage-east-1`         | S3 region name. |
| `bucket`            | `garage`                | Name of the created bucket. |
| `access-key-id`     | `GK...`                 | S3 access key ID. |
| `secret-access-key` | _(masked)_              | S3 secret access key. |

### Compatibility

Requires a Linux runner with Docker available. macOS and Windows runners are not supported.

| Platform               | Supported |
| ---------------------- | --------- |
| Linux runners (docker) | ✔️        |
| macOS runners          | ❌        |
| Windows runners        | ❌        |

Data is ephemeral: stored inside the container and discarded when the job ends. Only the S3 API port is published on the host; admin and RPC ports are not exposed. Garage requires authentication; anonymous access is not supported.

> This project is not affiliated with, endorsed by, or associated with the [Garage](https://garagehq.deuxfleurs.fr/) project or Deuxfleurs.
