"""Custom exception hierarchy for Listen backend."""


class ListenError(Exception):
    """Base exception for all Listen errors."""

    def __init__(self, message: str, component: str, recoverable: bool = True):
        super().__init__(message)
        self.component = component
        self.recoverable = recoverable


class AudioError(ListenError):
    def __init__(self, message: str, recoverable: bool = True):
        super().__init__(message, component="audio", recoverable=recoverable)


class TranscriptionError(ListenError):
    def __init__(self, message: str, recoverable: bool = True):
        super().__init__(message, component="transcription", recoverable=recoverable)


class LLMError(ListenError):
    def __init__(self, message: str, recoverable: bool = True):
        super().__init__(message, component="llm", recoverable=recoverable)


class KnowledgeBaseError(ListenError):
    def __init__(self, message: str, recoverable: bool = True):
        super().__init__(message, component="kb", recoverable=recoverable)


class ConfigError(ListenError):
    def __init__(self, message: str, recoverable: bool = True):
        super().__init__(message, component="config", recoverable=recoverable)
