#!/bin/sh
# Discover the package architectures an OpenWrt release publishes and map each
# to the Go environment that builds for it.
#
#   openwrt-arches.sh <release> [<release>...]
#
# Prints one JSON object per line: the SDK tag, the pkgarch, and the GOARCH,
# GOARM and GOMIPS the client must be cross-compiled with. Architectures Go
# cannot target are reported on stderr and left out.
#
# The list comes from downloads.openwrt.org rather than a file in the tree, so
# an architecture OpenWrt adds is built without an edit here. The mapping is
# derived from the pkgarch name because OpenWrt encodes the CPU and its FPU
# there and publishes nothing else machine-readable that carries it.

set -eu

[ $# -gt 0 ] || { echo "usage: openwrt-arches.sh <release>..." >&2; exit 2; }

# THE list of architecture families this feed serves. Everything downstream
# reads it from here -- the build matrix and the feed pages both come out of
# this script -- so widening coverage is a one-line edit and nothing else has
# to be kept in step.
#
# Shell glob patterns against the pkgarch name. `mips_*` is deliberately absent:
# that is big-endian MIPS, ath79 and lantiq, which this feed does not serve.
FAMILIES='x86_64 aarch64_* arm_* mipsel_*'

served() { # <pkgarch> -> 0 when a family matches
	for pattern in $FAMILIES; do
		# Unquoted on purpose: $pattern is a glob, not a literal.
		case "$1" in
		$pattern) return 0 ;;
		esac
	done
	return 1
}

# Floating point is the part worth getting right: a hardfloat binary on a
# softfloat target dies on the first FP instruction, while softfloat runs
# everywhere and only costs speed. Everything below therefore picks softfloat
# unless the pkgarch name advertises an FPU, and the client does little enough
# arithmetic that the difference does not show.
go_env_for() { # <pkgarch> -> "GOARCH GOARM GOMIPS GOMIPS64", "." for unset
	case "$1" in
	x86_64)            echo "amd64 . . ." ;;
	i386_*)            echo "386 . . ." ;;
	aarch64_*)         echo "arm64 . . ." ;;
	loongarch64_*)     echo "loong64 . . ." ;;
	riscv64_*)         echo "riscv64 . . ." ;;
	powerpc64_*)       echo "ppc64 . . ." ;;

	# GOARM 7 needs VFPv3 or better, 6 needs VFPv1, 5 is software floating
	# point. Only the names that advertise an FPU get more than 5.
	arm_*neon*|arm_*vfpv3*|arm_*vfpv4*)  echo "arm 7 . ." ;;
	arm_arm1176jzf-s_vfp)                echo "arm 6 . ." ;;
	arm_*)                               echo "arm 5 . ." ;;

	# 64-bit MIPS reads GOMIPS64, not GOMIPS. Emitting the wrong one is
	# silent: Go ignores it and falls back to hardfloat.
	mips64el_*)        echo "mips64le . . softfloat" ;;
	mips64_*)          echo "mips64 . . softfloat" ;;
	mipsel_*)          echo "mipsle . softfloat ." ;;
	mips_*)            echo "mips . softfloat ." ;;

	# Go has no linux/ppc (32-bit) and no big-endian ARM, so these cannot be
	# built at all rather than being an omission to fix later.
	powerpc_*|armeb_*) return 1 ;;
	*)                 return 1 ;;
	esac
}

for release in "$@"; do
	index=$(curl -fsS "https://downloads.openwrt.org/releases/$release/packages/") || {
		echo "cannot list architectures for $release" >&2
		exit 1
	}

	arches=$(printf '%s' "$index" |
		grep -oE 'href="[A-Za-z0-9_.-]+/"' |
		sed 's/href="//; s#/"##' |
		grep -vE '^\.\.?$' | sort -u)

	[ -n "$arches" ] || { echo "no architectures found for $release" >&2; exit 1; }

	skipped=
	for arch in $arches; do
		if ! served "$arch"; then
			skipped="$skipped $arch"
			continue
		fi
		# Reaching here means a family wants it but Go cannot build it, which
		# is worth a line of its own rather than being lost in the summary.
		if ! spec=$(go_env_for "$arch"); then
			echo "skipping $arch on $release: no Go target" >&2
			continue
		fi
		goarch=${spec%% *}; spec=${spec#* }
		goarm=${spec%% *};  spec=${spec#* }
		gomips=${spec%% *}
		gomips64=${spec#* }

		printf '{"sdk":"%s-%s","arch":"%s","release":"%s","goarch":"%s"' \
			"$arch" "$release" "$arch" "$release" "$goarch"
		[ "$goarm" = "." ]    || printf ',"goarm":"%s"' "$goarm"
		[ "$gomips" = "." ]   || printf ',"gomips":"%s"' "$gomips"
		[ "$gomips64" = "." ] || printf ',"gomips64":"%s"' "$gomips64"
		printf '}\n'
	done

	[ -z "$skipped" ] ||
		echo "$release: outside the served families, skipped:$skipped" >&2
done
