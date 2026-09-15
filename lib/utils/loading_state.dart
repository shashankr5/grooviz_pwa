enum LoadingState {
  idle,
  loading,
  success,
  error,
}

extension LoadingStateExtension on LoadingState {
  bool get isIdle => this == LoadingState.idle;
  bool get isLoading => this == LoadingState.loading;
  bool get isSuccess => this == LoadingState.success;
  bool get isError => this == LoadingState.error;
}
