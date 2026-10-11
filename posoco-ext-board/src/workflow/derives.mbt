///|
pub extend WorkflowScope with Eq::{equal, not_equal}

///|
pub extend WorkflowScope with @debug.Debug::{to_repr}

///|
pub extend WorkflowFailurePolicy with Eq::{equal, not_equal}

///|
pub extend WorkflowFailurePolicy with @debug.Debug::{to_repr}

///|
pub extend WorkflowRunSpec with Eq::{equal, not_equal}

///|
pub extend WorkflowRunSpec with @debug.Debug::{to_repr}

///|
pub extend WorkflowPhase with Eq::{equal, not_equal}

///|
pub extend WorkflowPhase with @debug.Debug::{to_repr}

///|
pub extend WorkflowStopReason with Eq::{equal, not_equal}

///|
pub extend WorkflowStopReason with @debug.Debug::{to_repr}

///|
pub extend WorkflowError with Eq::{equal, not_equal}

///|
pub extend WorkflowError with @debug.Debug::{to_repr}

///|
pub extend WorkflowStatus with Eq::{equal, not_equal}

///|
pub extend WorkflowStatus with @debug.Debug::{to_repr}
