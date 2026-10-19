# caravana-action

A GitHub Action that deploys an app to [Caravana](https://github.com/Cosmic-Chimps/caravana), a
self-hosted PaaS on Nomad. Your workflow builds and pushes the image; this step tells Caravana to
run it, waits until the app is healthy, prints the deploy's warnings, and fails the workflow with
Caravana's reason if the deploy fails or is reverted. It can also promote the deployment to another
environment (for example staging to production).

It is a client of Caravana's public HTTP API, written as one shell script (`caravana-deploy.sh`,
curl and jq only), so you can run the same script from other CI systems.

## Quick start

Build and push the image, then deploy the digest that was just pushed:

```yaml
name: Release
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: build
        uses: docker/build-push-action@v7
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:latest

      - uses: Cosmic-Chimps/caravana-action@v1
        with:
          url: https://caravana.example.com
          token: ${{ secrets.CARAVANA_TOKEN }}
          app: web
          image: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
```

To build for several platforms, add `docker/setup-buildx-action@v4` before the build step and set
`platforms` on `docker/build-push-action`.

Add `CARAVANA_TOKEN` to the repository's secrets (see the next section). The `app` is the app's ID
in Caravana. An app in project `default`, environment `production` has its bare name as its ID;
any other has `<project>--<environment>--<name>`. Instead of `app` you can give `project`,
`environment` and `name`, and the action works the ID out.

With `image`, only that image changes: the app's other settings (ports, environment, domains,
secrets, memory) stay as stored in Caravana. Without `image`, the stored app is deployed again and
its tags are looked up again.

## Deploy tokens

Give the workflow a token that can deploy one app and nothing else, so a leaked secret cannot reach
your other apps or Caravana's settings.

- In Caravana, open Settings, then API tokens, and create a token with "Only for one app" (the
  project and the app's name), or open the app's Configure page and choose "Create a deploy token
  for this app".
- The token is shown once. Store it as a repository (or environment) secret.
- A deploy token covers that app name in every environment of its project. It can read the app and
  its deployments, deploy it, create it without deploying, and preview and run promotions between
  its environments. Every other request answers 403.
- Deploy tokens arrived in Caravana 0.9.0. On an older Caravana, use a full API token until you
  upgrade.

A full API token works too, but give CI the narrow one.

## First deploy with a definition file

An app that does not exist yet, or was created without services, needs a definition. Commit a
JSON file holding the app, for example `deploy/caravana-app.json`:

```json
{
  "source": {"kind": "image"},
  "services": [
    {
      "name": "web",
      "image": "ghcr.io/acme/web:latest",
      "ports": [{"name": "http", "containerPort": 8080}],
      "domains": [{"host": "web.example.com", "port": "http"}],
      "health": {"path": "/healthz"}
    }
  ]
}
```

Then pass it, together with the image:

```yaml
      - uses: Cosmic-Chimps/caravana-action@v1
        with:
          url: https://caravana.example.com
          token: ${{ secrets.CARAVANA_TOKEN }}
          app: web
          definition: deploy/caravana-app.json
          image: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
```

The file is used only when the app is missing or has no definition. After that, the app stored in
Caravana is the truth and the file is ignored (with a notice in the log), so edits you make in the
Caravana console are never overwritten. See Caravana's `api/openapi.yaml` for every field of an app.

## Staging first, then production

Deploy to a staging environment, then promote the same healthy deployment (the same image digests)
to production. Put the promotion in a second job that uses a GitHub environment with required
reviewers, so someone approves it:

```yaml
jobs:
  staging:
    runs-on: ubuntu-latest
    steps:
      # ... build and push as above ...
      - uses: Cosmic-Chimps/caravana-action@v1
        with:
          url: https://caravana.example.com
          token: ${{ secrets.CARAVANA_TOKEN }}
          project: shop
          environment: staging
          name: web
          image: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}

  production:
    needs: staging
    runs-on: ubuntu-latest
    environment: production   # protection rules and required reviewers go here
    steps:
      - uses: Cosmic-Chimps/caravana-action@v1
        with:
          url: https://caravana.example.com
          token: ${{ secrets.CARAVANA_TOKEN }}
          project: shop
          environment: staging
          name: web
          promote: production
```

The second job gives `promote` and no `image` (and no `definition`), so it deploys nothing: it asks
Caravana to promote the source app's newest healthy deployment to `production`, and waits for that
promotion. Production runs exactly the image digests that staging's deployment pinned. If that
deployment is not healthy, Caravana refuses (for example `deployment_not_healthy`) and the step
fails with its message. The `production` app must already exist in the project. To promote in the
same job right after deploying, add `promote: production` to the staging step instead.

In that case the outputs `deployment-id`, `status` and `job-version` are empty and `promotion-id`
and `promotion-status` are set.

## Inputs

| Input | Required | Default | What it does |
| --- | --- | --- | --- |
| `url` | yes | | Your Caravana address, for example `https://caravana.example.com`. |
| `token` | yes | | An API token or a deploy token (`cvat_...`). Use a secret. |
| `app` | one of | | The app ID. |
| `project`, `environment`, `name` | one of | | The app's place, instead of `app`. All three are needed. |
| `image` | no | | The image to deploy, best pinned by digest. Without it, the stored app is deployed again. |
| `service` | no | | Which service gets the image. Needed when the app has more than one. |
| `definition` | no | | Path to a JSON file holding the app. Used when the app is missing or has no definition. |
| `wait` | no | `true` | Wait for the deployment to end. `false` prints the deployment ID and finishes. |
| `timeout` | no | `600` | Seconds to wait for a deployment (and again for a promotion). Caravana carries on after a timeout. |
| `promote` | no | | An environment of the app's project to promote to. With `image` or `definition`, the deployment is made first and promoted once healthy; alone, nothing is deployed and the newest healthy deployment is promoted. Needs `wait: true`. |
| `fail-on-superseded` | no | `false` | Fail the step when a newer deploy replaced this one. Caravana's newest deploy wins, so by default the older step passes. |

What happens, in order: the action reads the app; with only `promote` it goes straight to the promotion. Otherwise it sends the deploy (a new definition, the stored
app with the new image and `If-Match` so a concurrent edit is not overwritten, or an empty body to
redeploy); follows the deployment every 5 seconds until it is `healthy`, `failed`, `reverted` or
`superseded`; then promotes if asked. If the app changed between the read and the deploy (412
`app_changed`), it reads again and retries once.

## Outputs

| Output | What it holds |
| --- | --- |
| `app-id` | The app ID the step deployed. |
| `deployment-id` | The deployment's ID. |
| `job-version` | The Nomad job version of the deployment. |
| `status` | `healthy`, `failed`, `reverted`, `superseded`, or the last status seen when waiting stopped. |
| `promotion-id` | The promotion's deployment ID, when `promote` is set. |
| `promotion-status` | The promotion's final status, when `promote` is set. |
| `mode` | What the step did: `define` (the app got its definition from `definition`), `replace-image`, `redeploy` (as stored) or `promote-only`. The job summary says it too. |

The step also writes a table to the job summary (status, deployment, job version, image digests,
commit), prints Caravana's warnings as `::warning::` lines, and reports failures as `::error::` lines
naming the input to check or Caravana's `code: message`.

## What it sends

Each deploy and promotion carries where it came from, so Caravana can show "from CI: abc1234 on
main by ana" in the app's history and in notifications. Each header is sent only when its source
is set and valid; none is required.

| Header | Value |
| --- | --- |
| `Caravana-Origin-Commit` | `GITHUB_SHA` |
| `Caravana-Origin-Ref` | `GITHUB_REF`, for example `refs/heads/main` |
| `Caravana-Origin-Actor` | `GITHUB_ACTOR` |
| `Caravana-Origin-Run` | `GITHUB_SERVER_URL/GITHUB_REPOSITORY/actions/runs/GITHUB_RUN_ID` (https only) |
| `Caravana-Origin-Repository` | `GITHUB_REPOSITORY` |

Nothing else about your repository or workflow is sent.

## Security notes

- The token is masked in the log (`::add-mask::`) before anything else runs, and is never printed.
- The token reaches curl on its standard input, as a config line, so it never appears on a command
  line or in a process list. It goes only to the `url` you gave: a `Location` header naming another
  host is not followed with the token.
- A token containing characters a Caravana token never has (quotes, spaces, line breaks) is
  refused, so it cannot alter curl's configuration.
- Use `https://`. A plain `http://` address (other than localhost) works but prints a warning.
- Use a deploy token for one app, not a full API token.
- Pin the action to a commit SHA if you want to review updates, for example
  `Cosmic-Chimps/caravana-action@<sha>` instead of `@v1`.

## Requirements

- Caravana 0.7.0 or later (API 0.17, which says whether an app is defined yet). Deploying and
  promoting work there with a full API token.
- Caravana 0.9.0 or later (API 0.19) for deploy tokens (a token for one app) and for the deploy's
  origin (commit, ref, actor, run) being recorded and shown; an older Caravana ignores the
  origin headers.
- A runner with bash, curl and jq. GitHub-hosted Linux and macOS runners have all three.

## Development

```sh
bash test/run.sh        # runs the script against test/fake_caravana.py (Python 3, standard library only)
shellcheck caravana-deploy.sh test/run.sh
```

## License

MIT. See `LICENSE`.
