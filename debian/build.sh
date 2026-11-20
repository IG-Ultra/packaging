#!/usr/bin/env bash
# Builds Debian source and binary packages from the project checkouts next to
# this repository. Packages are built in dependency order, taken from the
# Build-Depends and Depends in their control files. Each package is built from
# its checkout's committed HEAD; the results go to out/debian/. A native
# package, such as the cutefish-desktop metapackage, has no checkout and is
# built from its packaging alone. A package with a debian/<project>/upstream
# file, such as cutefish-ghostty-vt, is built from the release tarballs it pins,
# downloaded and checked against their SHA-256 and minisign signatures.
#
#   debian/build.sh                            # every package
#   debian/build.sh cutefish-core settings     # just these
#   debian/build.sh --install                  # every package, each installed
#                                              # before the ones that need it
#   debian/build.sh --snapshot                 # versioned after the commit,
#                                              # e.g. 1.0~git20261020120000.1a2b3c4-1
#                                              # (a native package: 1.0+git...)
#   debian/build.sh --snapshot --build 20261020130000
#                                              # and marked as this build,
#                                              # e.g. 1.0~git20261020120000.1a2b3c4-1+ci20261020130000
#   debian/build.sh --skip cutefish-webkit     # every package but this one
set -Eeuo pipefail

PACKAGING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$(dirname "$PACKAGING")"
OUT="$PACKAGING/out/debian"

INSTALL=false
SNAPSHOT=false
BUILD=
SKIP=()
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --install) INSTALL=true ;;
    --snapshot) SNAPSHOT=true ;;
    --build) BUILD="${2:?--build needs an id}"; shift ;;
    --skip) SKIP+=("${2:?--skip needs a project}"); shift ;;
    *) echo "Error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ -n "$BUILD" && "$SNAPSHOT" == false ]]; then
  echo "Error: --build needs --snapshot" >&2
  exit 1
fi

SUDO=(sudo)
if (( EUID == 0 )); then
  SUDO=()
fi

ALL=()
declare -A VERSIONS=()
while read -r project version; do
  [[ -z "$project" || "$project" == \#* ]] && continue
  ALL+=("$project")
  VERSIONS[$project]="$version"
done < "$PACKAGING/versions"

for name in "$@" "${SKIP[@]}"; do
  [[ -n "${VERSIONS[$name]:-}" ]] || { echo "Error: $name is not in versions" >&2; exit 1; }
done

# Which project builds each binary package.
declare -A OWNER=()
for project in "${ALL[@]}"; do
  while read -r package; do
    OWNER[$package]="$project"
  done < <(awk '/^Package:/ { print $2 }' "$PACKAGING/debian/$project/debian/control")
done

# The other projects a project's control file names in its build or runtime
# dependencies.
dependencies() {
  local word
  awk '/^[A-Za-z-]+:/ { field = ($1 == "Build-Depends:" || $1 == "Build-Depends-Indep:" || $1 == "Depends:") }
       field { sub(/^[A-Za-z-]+:/, ""); gsub(/\([^)]*\)|\[[^]]*\]|<[^>]*>|[,|]/, " "); print }' \
    "$PACKAGING/debian/$1/debian/control" \
    | tr -s ' \t' '\n' | while read -r word; do
        [[ -n "$word" && -n "${OWNER[$word]:-}" && "${OWNER[$word]}" != "$1" ]] && echo "${OWNER[$word]}"
      done | sort -u
}

# Depth-first, so a project comes after everything it depends on; ties keep
# the order of the versions file.
ORDER=()
declare -A STATE=()
visit() {
  local project="$1" dependency
  [[ "${STATE[$project]:-}" == done ]] && return
  if [[ "${STATE[$project]:-}" == visiting ]]; then
    echo "Error: dependency cycle through $project" >&2
    exit 1
  fi
  STATE[$project]=visiting
  for dependency in $(dependencies "$project"); do
    visit "$dependency"
  done
  STATE[$project]=done
  ORDER+=("$project")
}
for project in "${ALL[@]}"; do
  visit "$project"
done

PROJECTS=()
for project in "${ORDER[@]}"; do
  [[ " ${SKIP[*]} " == *" $project "* ]] && continue
  if (( $# == 0 )) || [[ " $* " == *" $project "* ]]; then
    PROJECTS+=("$project")
  fi
done

echo "Build order: ${PROJECTS[*]}"

if [[ "$INSTALL" == true ]]; then
  command -v mk-build-deps >/dev/null && dpkg -s equivs >/dev/null 2>&1 \
    || { echo "Error: --install needs devscripts and equivs" >&2; exit 1; }
  "${SUDO[@]}" true
fi

mkdir -p "$OUT"

# Downloads the tarballs debian/$1/upstream pins as the .orig tarballs of
# $2 $3, unless they are there already, and checks each one: its SHA-256 and
# its minisign signature with the pinned key. The line named orig is the main
# tarball, each other line a component of its name.
fetch_upstream() {
  local pins="$PACKAGING/debian/$1/upstream" source="$2" upstream="$3"
  local key name url sha256 file
  key="$(awk '$1 == "minisign-key" { print $2 }' "$pins")"
  command -v minisign >/dev/null || { echo "Error: $1 needs minisign to check its tarballs" >&2; exit 1; }
  while read -r name url sha256; do
    [[ -z "$name" || "$name" == \#* || "$name" == minisign-key ]] && continue
    file="$OUT/${source}_$upstream.orig.tar.gz"
    [[ "$name" == orig ]] || file="$OUT/${source}_$upstream.orig-$name.tar.gz"
    if ! echo "$sha256  $file" | sha256sum --check --quiet --status 2>/dev/null; then
      curl -fsSL -o "$file" "$url"
      echo "$sha256  $file" | sha256sum --check --quiet
    fi
    curl -fsSL -o "$file.minisig" "$url.minisig"
    minisign -Vq -P "$key" -m "$file" -x "$file.minisig"
    rm -f "$file.minisig"
  done < "$pins"
}

# Unpacks the tarballs fetch_upstream left, the components into directories
# of their names, as dpkg-source unpacks them.
unpack_upstream() {
  local project="$1" source="$2" upstream="$3" tree="$4" name
  mkdir -p "$tree"
  tar -xzf "$OUT/${source}_$upstream.orig.tar.gz" -C "$tree" --strip-components=1
  while read -r name _; do
    [[ -z "$name" || "$name" == \#* || "$name" == minisign-key || "$name" == orig ]] && continue
    mkdir -p "$tree/$name"
    tar -xzf "$OUT/${source}_$upstream.orig-$name.tar.gz" -C "$tree/$name" --strip-components=1
  done < "$PACKAGING/debian/$project/upstream"
}

# Installs the binary packages just built for $source $version.
install_built() {
  [[ "$INSTALL" == true ]] || return 0
  local debs=() deb
  while read -r deb; do
    [[ "$deb" == *-dbgsym_* ]] || debs+=("$deb")
  done < <(dcmd --deb "$OUT/${source}_${version}_$(dpkg-architecture -qDEB_HOST_ARCH).changes")
  "${SUDO[@]}" apt-get install --yes --reinstall "${debs[@]}"
}

for project in "${PROJECTS[@]}"; do
  src="$SOURCES/$project"
  packaging="$PACKAGING/debian/$project/debian"
  changelog="$packaging/changelog"

  native=false
  if [[ "$(cat "$packaging/source/format" 2>/dev/null)" == "3.0 (native)" ]]; then
    native=true
  fi
  released=false
  if [[ -f "$PACKAGING/debian/$project/upstream" ]]; then
    released=true
  fi

  if [[ "$native" == false && "$released" == false ]] && ! git -C "$src" rev-parse --verify --quiet HEAD >/dev/null; then
    echo "Error: $src is not a Git checkout with a commit" >&2
    exit 1
  fi

  source="$(dpkg-parsechangelog -l "$changelog" -S Source)"
  version="$(dpkg-parsechangelog -l "$changelog" -S Version)"
  upstream="${version%-*}"
  if [[ "$upstream" != "${VERSIONS[$project]}" ]]; then
    echo "Error: $project's changelog is at $version, versions says ${VERSIONS[$project]}" >&2
    exit 1
  fi

  # A released tarball has no commit to name a snapshot after.
  if [[ "$SNAPSHOT" == true && "$native" == false && "$released" == false ]]; then
    stamp="$(TZ=UTC0 git -C "$src" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd HEAD)"
    upstream="$upstream~git$stamp.$(git -C "$src" rev-parse --short=7 HEAD)"
    version="$upstream-${version##*-}"
  fi

  # A native package was first published at its plain version, so its
  # snapshots sort after it and are named for the last commit to its packaging.
  if [[ "$SNAPSHOT" == true && "$native" == true ]]; then
    stamp="$(TZ=UTC0 git -C "$PACKAGING" log -1 --date=format-local:%Y%m%d%H%M%S --format=%cd -- "debian/$project")"
    version="$upstream+git$stamp.$(git -C "$PACKAGING" log -1 --abbrev=7 --format=%h -- "debian/$project")"
  fi

  # A rebuild of an unchanged commit differs from the published one, and
  # PackageKit installs no update whose version is the one installed. A +b
  # suffix would mark a binNMU, which dpkg-genchanges takes off the source.
  if [[ -n "$BUILD" ]]; then
    version="$version+ci$BUILD"
  fi

  echo
  echo "==> [$project] $source $version"

  if [[ "$INSTALL" == true ]]; then
    (cd "$OUT" && "${SUDO[@]}" mk-build-deps -i -r \
      -t "apt-get --yes --no-install-recommends" "$packaging/control")
  fi

  if [[ "$released" == true ]]; then
    tree="$OUT/$source-$upstream"
    rm -rf "$tree"
    fetch_upstream "$project" "$source" "$upstream"
    unpack_upstream "$project" "$source" "$upstream" "$tree"
    cp -a "$packaging" "$tree/debian"
    if [[ -n "$BUILD" ]]; then
      (cd "$tree" && DEBEMAIL="$(dpkg-parsechangelog -S Maintainer)" \
        dch --newversion "$version" --distribution UNRELEASED "Rebuild $BUILD.")
    fi
    (cd "$tree" && dpkg-buildpackage -us -uc)
    rm -rf "$tree"
    install_built
    echo "==> [$project] OK"
    continue
  fi

  if [[ "$native" == true ]]; then
    tree="$OUT/$source-$version"
    rm -rf "$tree"
    mkdir -p "$tree"
    cp -a "$packaging" "$tree/debian"
    if [[ "$SNAPSHOT" == true ]]; then
      (cd "$tree" && DEBEMAIL="$(dpkg-parsechangelog -S Maintainer)" \
        dch --newversion "$version" --distribution UNRELEASED \
          "Snapshot of commit $(git -C "$PACKAGING" log -1 --format=%H -- "debian/$project").")
    fi
    (cd "$tree" && dpkg-buildpackage -us -uc)
    rm -rf "$tree"
    install_built
    echo "==> [$project] OK"
    continue
  fi

  tree="$OUT/$source-$upstream"
  rm -rf "$tree"
  git -C "$src" archive --prefix="$source-$upstream/" -o "$OUT/${source}_$upstream.orig.tar" HEAD
  # Trees the project fetches rather than tracks, such as a pinned library's
  # sources, are taken from the checkout's working tree.
  vendor="$PACKAGING/debian/$project/vendor"
  if [[ -f "$vendor" ]]; then
    paths=()
    excludes=(--exclude=.git)
    while read -r path; do
      [[ -z "$path" || "$path" == \#* ]] && continue
      if [[ "$path" == !* ]]; then
        excludes+=("--exclude=${path#!}")
      elif [[ -d "$src/$path" ]]; then
        paths+=("$path")
      else
        echo "Error: $src/$path is missing; fetch it first" >&2
        exit 1
      fi
    done < "$vendor"
    tar -rf "$OUT/${source}_$upstream.orig.tar" -C "$src" "${excludes[@]}" \
      --owner=0 --group=0 --numeric-owner --transform="s|^|$source-$upstream/|" "${paths[@]}"
  fi
  xz -T0 -f "$OUT/${source}_$upstream.orig.tar"
  tar -xf "$OUT/${source}_$upstream.orig.tar.xz" -C "$OUT"
  # An older commit may still carry its own debian/.
  rm -rf "$tree/debian"
  cp -a "$packaging" "$tree/debian"
  if [[ "$SNAPSHOT" == true ]]; then
    # A snapshot sorts before the release it leads up to, which dch only
    # writes when forced.
    (cd "$tree" && DEBEMAIL="$(dpkg-parsechangelog -S Maintainer)" \
      dch --force-bad-version --newversion "$version" --distribution UNRELEASED \
        "Snapshot of commit $(git -C "$src" rev-parse HEAD).")
  fi

  (cd "$tree" && dpkg-buildpackage -us -uc)
  rm -rf "$tree"
  install_built

  echo "==> [$project] OK"
done
