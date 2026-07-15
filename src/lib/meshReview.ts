import type { WorktreeFile } from './bridge'

export type MeshReviewVerdict = 'approve' | 'changes-requested' | 'blocked'

export interface MeshReviewReceipt {
  candidateThreadId: string
  reviewedCommit: string
  verdict: MeshReviewVerdict
  reviewedFiles: string[]
  tests: string[]
  blockingFindings: string[]
}

export interface MeshReviewExpectation {
  candidateThreadId: string
  reviewedCommit: string
  files: WorktreeFile[]
}

export type MeshReviewValidation =
  | { ok: true; receipt: MeshReviewReceipt }
  | { ok: false; message: string; receipt?: MeshReviewReceipt }

const RECEIPT_MARKER = 'MESH_REVIEW_RECEIPT'
const verdicts = new Set<MeshReviewVerdict>(['approve', 'changes-requested', 'blocked'])

function jsonObjectAfterMarker(text: string): unknown {
  const markerAt = text.lastIndexOf(RECEIPT_MARKER)
  if (markerAt < 0) return undefined
  const start = text.indexOf('{', markerAt + RECEIPT_MARKER.length)
  if (start < 0) return undefined
  let depth = 0
  let quoted = false
  let escaped = false
  for (let index = start; index < text.length; index += 1) {
    const char = text[index]
    if (quoted) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') quoted = false
      continue
    }
    if (char === '"') quoted = true
    else if (char === '{') depth += 1
    else if (char === '}' && --depth === 0) {
      try { return JSON.parse(text.slice(start, index + 1)) } catch { return undefined }
    }
  }
  return undefined
}

function normalizeReceipt(value: unknown): MeshReviewReceipt | undefined {
  if (!value || typeof value !== 'object') return undefined
  const row = value as Record<string, unknown>
  if (typeof row.candidateThreadId !== 'string' || typeof row.reviewedCommit !== 'string' || !verdicts.has(row.verdict as MeshReviewVerdict)) return undefined
  if (![row.reviewedFiles, row.tests, row.blockingFindings].every((field) => Array.isArray(field) && field.every((item) => typeof item === 'string'))) return undefined
  return {
    candidateThreadId: row.candidateThreadId,
    reviewedCommit: row.reviewedCommit,
    verdict: row.verdict as MeshReviewVerdict,
    reviewedFiles: [...new Set(row.reviewedFiles as string[])],
    tests: row.tests as string[],
    blockingFindings: row.blockingFindings as string[],
  }
}

export function validateMeshReviewReceiptObject(receipt: MeshReviewReceipt | undefined, expected: MeshReviewExpectation): MeshReviewValidation {
  if (!receipt) return { ok: false, message: 'missing the machine-readable review receipt' }
  if (receipt.candidateThreadId !== expected.candidateThreadId) return { ok: false, message: 'named the wrong candidate' , receipt }
  if (receipt.reviewedCommit !== expected.reviewedCommit) return { ok: false, message: 'did not attest the frozen candidate commit', receipt }
  const wanted = [...new Set(expected.files.map((file) => file.path))].sort()
  const covered = [...new Set(receipt.reviewedFiles)].sort()
  const missing = wanted.filter((file) => !covered.includes(file))
  const unexpected = covered.filter((file) => !wanted.includes(file))
  if (missing.length || unexpected.length) {
    const detail = [missing.length ? `missing ${missing.join(', ')}` : '', unexpected.length ? `unexpected ${unexpected.join(', ')}` : ''].filter(Boolean).join('; ')
    return { ok: false, message: `reported incomplete file coverage (${detail})`, receipt }
  }
  if (receipt.verdict !== 'approve') return { ok: false, message: `returned verdict ${receipt.verdict}`, receipt }
  if (receipt.blockingFindings.length) return { ok: false, message: 'reported blocking findings', receipt }
  return { ok: true, receipt }
}

export function parseAndValidateMeshReviewReceipt(text: string, expected: MeshReviewExpectation): MeshReviewValidation {
  const parsed = normalizeReceipt(jsonObjectAfterMarker(text))
  if (!parsed) return { ok: false, message: `missing or malformed ${RECEIPT_MARKER} JSON` }
  return validateMeshReviewReceiptObject(parsed, expected)
}
