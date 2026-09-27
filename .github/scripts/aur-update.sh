#!/usr/bin/env bash
#
# Keep herta-bin (AUR) in step with the upstream Herta release.
#
#   detect newest release -> update pkgver/pkgrel/sha256sums -> build to verify
#   -> regenerate .SRCINFO -> commit to this mirror -> push to the AUR
#
# The AUR keeps the package files only: the commit pushed there is this tree
# minus .github/, so CI plumbing never lands in the AUR repository.
#
# Environment overrides (all optional):
#   GH_TOKEN     GitHub token for the API call; avoids the anonymous rate limit
#   DRY_RUN      "true" to stop after the verification build
#   AUR_URL      git remote to push to (a local path is handy for testing)
#   AUR_SSH_KEY  private key used for the AUR push (default ~/.ssh/aur)
set -euo pipefail

UPSTREAM=${UPSTREAM:-PersonaCLI/Herta}
ASSET=${ASSET:-Herta-x86_64.AppImage}
AUR_URL=${AUR_URL:-ssh://aur@aur.archlinux.org/herta-bin.git}
AUR_SSH_KEY=${AUR_SSH_KEY:-$HOME/.ssh/aur}
DRY_RUN=${DRY_RUN:-false}
GIT_NAME=${GIT_NAME:-AnRan}
GIT_EMAIL=${GIT_EMAIL:-2318621872@qq.com}

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m==> %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")/../.."
[ -f PKGBUILD ] || die "PKGBUILD not found in $PWD"

# makepkg refuses to run as root, and the CI container is root.
run_makepkg() {
  if [ "$(id -u)" -ne 0 ]; then
    makepkg "$@"
    return
  fi
  git config --global --add safe.directory "$PWD"
  id -u builder >/dev/null 2>&1 || useradd -m builder
  chown -R builder:builder "$PWD"
  runuser -u builder -- makepkg "$@"
}

# ---------- what we ship today ----------
cur_ver=$(sed -n 's/^pkgver=//p' PKGBUILD)
cur_rel=$(sed -n 's/^pkgrel=//p' PKGBUILD)
cur_sha=$(sed -n "s/^sha256sums=('\\([0-9a-f]\\{64\\}\\)'.*/\\1/p" PKGBUILD)
[ -n "$cur_ver" ] || die "cannot read pkgver from PKGBUILD"
[ -n "$cur_sha" ] || die "cannot read the AppImage checksum from PKGBUILD"
log "current: ${cur_ver}-${cur_rel} (${cur_sha:0:12}...)"

# ---------- what upstream has ----------
log "querying the newest ${UPSTREAM} release"
if [ -n "${GH_TOKEN:-}" ]; then
  release=$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${UPSTREAM}/releases/latest")
else
  release=$(curl -fsSL "https://api.github.com/repos/${UPSTREAM}/releases/latest")
fi

tag=$(jq -r '.tag_name // empty' <<<"$release")
new_ver=${tag#v}
[ -n "$new_ver" ] || die "the newest release has no tag_name"

new_sha=$(jq -r --arg a "$ASSET" \
  '.assets[] | select(.name == $a) | .digest // empty' <<<"$release")
new_sha=${new_sha#sha256:}

if [ -z "$new_sha" ]; then
  log "no digest published for ${ASSET}; downloading it to hash"
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://github.com/${UPSTREAM}/releases/download/${tag}/${ASSET}"
  new_sha=$(sha256sum "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
fi
log "upstream: ${new_ver} (${new_sha:0:12}...)"

# ---------- is there anything to do? ----------
if [ "$new_ver" = "$cur_ver" ] && [ "$new_sha" = "$cur_sha" ]; then
  log "already up to date"
  exit 0
fi

if [ "$new_ver" = "$cur_ver" ]; then
  new_rel=$((cur_rel + 1))
  reason="${ASSET} was re-released for ${new_ver}"
else
  new_rel=1
  reason="upstream release ${tag}"
fi
log "updating to ${new_ver}-${new_rel} (${reason})"

sed -i "s/^pkgver=.*/pkgver=${new_ver}/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=${new_rel}/" PKGBUILD
sed -i "s/^sha256sums=('[0-9a-f]\\{64\\}'/sha256sums=('${new_sha}'/" PKGBUILD

# ---------- prove the new release still packages ----------
if [ "$(id -u)" -eq 0 ]; then
  log "installing the build dependencies"
  deps=$(run_makepkg --printsrcinfo |
    awk -F' = ' '$1 == "\tdepends" || $1 == "\tmakedepends" { print $2 }')
  # shellcheck disable=SC2086
  pacman -S --noconfirm --needed $deps
fi

log "building the package"
run_makepkg --noconfirm --force --cleanbuild --nocheck

log "regenerating .SRCINFO"
run_makepkg --printsrcinfo > .SRCINFO

if [ "$DRY_RUN" = "true" ]; then
  log "dry run: stopping before the commit"
  git --no-pager diff --stat
  exit 0
fi

# ---------- publish ----------
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
git add PKGBUILD .SRCINFO
git commit -q -m "herta-bin ${new_ver}-${new_rel}" -m "Automated update: ${reason}."

log "pushing to the GitHub mirror"
git push -q origin HEAD:master

log "pushing to the AUR"
[ -f "$AUR_SSH_KEY" ] || die "AUR SSH key not found at $AUR_SSH_KEY"
export GIT_SSH_COMMAND="ssh -i $AUR_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

git remote remove aur >/dev/null 2>&1 || true
git remote add aur "$AUR_URL"
git fetch -q aur master >/dev/null 2>&1 || true
parent=$(git rev-parse --verify -q FETCH_HEAD || true)

# Same tree as this commit, without the CI plumbing.
aur_tree=$(git ls-tree "$(git rev-parse 'HEAD^{tree}')" | sed $'/\t\\.github$/d' | git mktree)

if [ -n "$parent" ] && [ "$(git rev-parse "${parent}^{tree}")" = "$aur_tree" ]; then
  log "the AUR copy is already identical; nothing to push"
  exit 0
fi

args=()
[ -n "$parent" ] && args=(-p "$parent")
aur_commit=$(git commit-tree "$aur_tree" "${args[@]}" \
  -m "herta-bin ${new_ver}-${new_rel}" -m "Automated update: ${reason}.")
git push aur "${aur_commit}:master"

log "published herta-bin ${new_ver}-${new_rel}"
