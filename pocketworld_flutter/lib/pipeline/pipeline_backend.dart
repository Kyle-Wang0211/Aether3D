// Dart port of Core/Pipeline/PipelineBackend.swift.
//
// Backend selector. `productDefault()` picks brokered-background-upload
// if config is present, falls back to NotConfigured otherwise. SSH /
// localEmbedded are legacy options retained for compatibility — the
// Dart app today only implements the broker path.

import 'broker_config.dart';

enum PipelineBackend {
  localEmbedded,
  danishGoldenSSH,
  brokeredBackgroundUpload,
  notConfigured,
}

PipelineBackend pipelineBackendProductDefault() {
  if (BackgroundUploadBrokerConfiguration.current() != null) {
    return PipelineBackend.brokeredBackgroundUpload;
  }
  return PipelineBackend.notConfigured;
}
