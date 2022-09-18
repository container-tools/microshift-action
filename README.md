# MicroShift OpenShift Cluster Action

[![Test](https://github.com/container-tools/microshift-action/workflows/Test/badge.svg?branch=main)](https://github.com/container-tools/microshift-action/actions)

A GitHub Action for starting an OpenShift cluster using [MicroShift](https://github.com/redhat-et/microshift).

## Supported runners

Right now, this action only supports the following GitHub-hosted runner:

- `ubuntu-20.04`

## Usage

### Pre-requisites

Create a workflow YAML file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
For more information, reference the GitHub Docs for [Understanding GitHub Actions](https://docs.github.com/en/actions/learn-github-actions/understanding-github-actions).

### Inputs

For more information on inputs, see the [API Documentation](https://developer.github.com/v3/repos/releases/#input).

- `version`: The MicroShift version to use (default: latest version)

### Example Workflow

Create a workflow (eg: `.github/workflows/create-cluster.yml`):

```yaml
name: Create Cluster

on: pull_request

jobs:
  create-cluster:
    runs-on: ubuntu-latest
    steps:
      - name: MicroShift OpenShift Cluster
        uses: container-tools/microshift-action@v0.3
```

This uses [@container-tools/microshift-action](https://www.github.com/container-tools/microshift-action) GitHub Action to spin up a [MicroShift](https://github.com/redhat-et/microshift) OpenShift cluster on every Pull Request.
