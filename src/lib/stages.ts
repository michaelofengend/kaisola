import type { TrajectoryStage } from '../domain/types'

export interface StageMeta {
  id: TrajectoryStage
  label: string
  short: string
  /** lucide-react icon name. */
  icon: string
  blurb: string
}

/** The trajectory spine, in order. The left rail renders exactly this. */
export const STAGES: StageMeta[] = [
  { id: 'corpus', label: 'Corpus', short: 'Corpus', icon: 'Library', blurb: 'Papers, repos, datasets & notes' },
  { id: 'claims', label: 'Claim Graph', short: 'Claims', icon: 'Network', blurb: 'Claims, methods, limitations & contradictions' },
  { id: 'questions', label: 'Questions', short: 'Questions', icon: 'HelpCircle', blurb: 'Open research questions' },
  { id: 'campaign', label: 'Campaign', short: 'Campaign', icon: 'Target', blurb: 'Objective, evaluator, budget & attempts' },
  { id: 'ideas', label: 'Ideas', short: 'Ideas', icon: 'Lightbulb', blurb: 'Evidence-grounded hypotheses' },
  { id: 'experiments', label: 'Experiments', short: 'Plan', icon: 'ListChecks', blurb: 'Specs, baselines, ablations & metrics' },
  { id: 'runs', label: 'Runs', short: 'Runs', icon: 'Terminal', blurb: 'Execution & the auto lab notebook' },
  { id: 'analysis', label: 'Analysis', short: 'Analysis', icon: 'BarChart3', blurb: 'Results, figures — real or noise?' },
  { id: 'manuscript', label: 'Manuscript', short: 'Write', icon: 'FileText', blurb: 'Artifact-grounded writing & trust' },
  { id: 'review', label: 'Review', short: 'Review', icon: 'Gavel', blurb: 'Simulated peer review' },
  { id: 'files', label: 'Files', short: 'Files', icon: 'FolderTree', blurb: 'Browse the workspace repo' },
]

export function stageMeta(id: TrajectoryStage): StageMeta {
  return STAGES.find((s) => s.id === id) ?? STAGES[0]
}

// The stage-navigation UI (NAV_GROUPS, WORKBENCH_TABS and the 11 trajectory
// views) was deleted 2026-07 — the shell is IDE-first. STAGES survives because
// the AGENT layer still runs on the trajectory: proposals carry a stage, the
// supervisor maps stages to agents, and the chat context names the stage.
