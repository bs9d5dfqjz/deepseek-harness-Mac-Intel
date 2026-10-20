#!/usr/bin/env node
/**
 * Pre-fetch the locked Desktop runtime payload for mac-x64 into the packaging
 * download cache. The packaging step addresses that cache by SHA-256, so a
 * verified file here is reused without another network request.
 *
 * Usage:
 *   node scripts/prefetch-macos-x64-runtime.mjs [repository-root] [cache-directory]
 *
 * Environment:
 *   DSH_GITHUB_PROXY  Prefix used when a GitHub release asset cannot be reached
 *                     directly (default: https://gh-proxy.com/). Set it to an
 *                     empty string to disable the fallback.
 *
 * Every asset is verified against scripts/primary-runtime/lock.json; a mirror
 * cannot substitute different bytes.
 */
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(process.argv[2] ?? fileURLToPath(new URL('..', import.meta.url)))
const cache = process.argv[3]
  ? resolve(process.argv[3])
  : join(root, 'apps/desktop/.desktop-build/downloads')
const lock = JSON.parse(readFileSync(join(root, 'scripts/primary-runtime/lock.json'), 'utf8'))
const target = lock.targets['mac-x64']
if (target === undefined) throw new Error('prefetch: lock.json has no mac-x64 target')
const proxySetting = process.env.DSH_GITHUB_PROXY ?? 'https://gh-proxy.com/'
const proxy = proxySetting === '' ? '' : `${proxySetting.replace(/\/+$/u, '')}/`

const pythonName = `cpython-${lock.pythonVersion}+${lock.pythonRelease}-${target.pythonTarget}-install_only_stripped.tar.gz`
const nodeName = `node-v${lock.nodeVersion}-${target.nodeArchive}`
const assets = [
  {
    name: nodeName,
    kind: 'node',
    url: `https://nodejs.org/dist/v${lock.nodeVersion}/${nodeName}`,
    sha256: target.nodeSha256,
  },
  {
    name: pythonName,
    kind: 'python',
    url: `https://github.com/astral-sh/python-build-standalone/releases/download/${lock.pythonRelease}/${encodeURIComponent(pythonName)}`,
    sha256: target.pythonSha256,
  },
  ...[...target.wheels, ...lock.wheels].map(wheel => ({
    name: wheel.url.split('/').at(-1),
    kind: 'wheel',
    url: wheel.url,
    sha256: wheel.sha256,
  })),
]

const digest = file => createHash('sha256').update(readFileSync(file)).digest('hex')
const failedHosts = new Set()
const hostOf = url => {
  try {
    return new URL(url).host
  } catch {
    return url
  }
}

/**
 * Direct source first, then mirrors that carry the same immutable archive.
 * @param asset - Locked runtime asset.
 * @returns Candidate URLs in preference order.
 */
function candidates(asset) {
  const urls = [asset.url]
  if (asset.kind === 'node') {
    urls.push(`https://npmmirror.com/mirrors/node/v${lock.nodeVersion}/${nodeName}`)
  }
  if (asset.kind === 'python' && proxy !== '') {
    urls.push(`${proxy}${asset.url}`)
  }
  if (asset.kind === 'wheel') {
    const path = new URL(asset.url).pathname
    urls.push(`https://pypi.tuna.tsinghua.edu.cn${path}`, `https://mirrors.aliyun.com/pypi${path}`)
  }
  // A host that already exhausted its retries for this payload moves behind the
  // mirrors, so one slow origin does not add a stall before every later asset.
  return [...new Set(urls)].sort((left, right) =>
    Number(failedHosts.has(hostOf(left))) - Number(failedHosts.has(hostOf(right))))
}

mkdirSync(cache, { recursive: true })
let failed = 0
for (const asset of assets) {
  const destination = join(cache, asset.sha256)
  if (existsSync(destination) && digest(destination) === asset.sha256) {
    console.log(`cached    ${asset.name}`)
    continue
  }
  let saved = false
  for (const url of candidates(asset)) {
    console.log(`fetching  ${asset.name} from ${hostOf(url)}`)
    const temporary = `${destination}.${process.pid}.tmp`
    rmSync(temporary, { force: true })
    const result = spawnSync('curl', [
      '-4', '-sSL', '--connect-timeout', '20', '--speed-time', '20', '--speed-limit', '20480',
      '-m', '300', '--retry', '2', '--retry-delay', '2', '-o', temporary, url,
    ], { stdio: 'inherit' })
    if (result.status === 0 && existsSync(temporary) && digest(temporary) === asset.sha256) {
      renameSync(temporary, destination)
      console.log(`fetched   ${asset.name}`)
      saved = true
      break
    }
    rmSync(temporary, { force: true })
    failedHosts.add(hostOf(url))
  }
  if (!saved) {
    console.error(`failed    ${asset.name}`)
    failed += 1
  }
}

if (failed > 0) {
  console.error(`prefetch: ${failed} asset(s) unavailable; packaging will retry them itself.`)
  process.exit(1)
}
console.log(`prefetch: ${assets.length} asset(s) verified in ${cache}`)
