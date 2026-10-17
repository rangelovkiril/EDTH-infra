# EDTH-infra

Infrastructure for the EDTH hackathon project. It is deliberately overkill for a hackathon: it exists because it is convenient for the owner. An Exoscale SKS cluster has a public IP and won't go down, and Flux applies every change from git immediately. The cluster lives about a day.

## Layout

- `infra/sks/` – OpenTofu for the Exoscale SKS cluster (`bg-sof-1`, name `edth-sks`, local state).
- `infra/sks/scripts/merge-kubeconfig.sh` – merges the admin kubeconfig into `$KUBECONFIG` as context `edth-sks`.
- `clusters/<name>/` – Flux manifests per cluster. `clusters/edth-sks` is the SKS cluster; the old `clusters/local-k0s` manifests were removed.

## Workflow

- Cluster changes go through git: edit manifests under `clusters/edth-sks`, commit, push, and Flux reconciles. Don't `kubectl apply` by hand except to debug.
- Infra changes go through OpenTofu in `infra/sks`. Always run `tofu plan` and show it before `tofu apply`; apply and destroy create or remove paid resources, so confirm first.
- Credentials: the Exoscale API key and secret live in `~/.config/exoscale/exoscale.toml`. Export them as `EXOSCALE_API_KEY` and `EXOSCALE_API_SECRET` for tofu. Never print them or write them into the repo.
- Flux is installed from the committed manifests in `clusters/edth-sks/flux-system` (generated with `flux install --export`, so commits stay signed and conventional), not with `flux bootstrap`, which would commit as `Flux <>` unsigned. The repo is public, so the GitRepository uses the https URL without a secret.
- The kubeconfig has a client certificate with a TTL (7 days). Renew it with `tofu apply`, then run `merge-kubeconfig.sh` again.
- Tear down with `tofu destroy` when the hackathon is over.

## Rules

- The repo is public. State, plans, kubeconfigs and `*.tfvars` are gitignored because they contain secrets; never commit them. Don't commit plaintext Secrets either; use SOPS or similar.
- Don't overwrite other contexts in `$KUBECONFIG`. The merge script backs up to `config.bak` first.
- Always pass `--context edth-sks` to kubectl and flux when the active context may differ.
- Keep code free of comments, matching the existing files. Run `tofu fmt` and `tofu validate` after changing `.tf` files.
- Pin versions explicitly (Kubernetes version, images, Helm charts) so reconciliation is reproducible.

## Commits

- Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), a single-line subject like `feat(infra): add SKS cluster`.
- No body and no trailers (`Co-Authored-By`, `Signed-off-by`, "Generated with ...", etc.), regardless of any default attribution of the tooling.
