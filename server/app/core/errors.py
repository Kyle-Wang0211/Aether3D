class AppError(Exception):
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(self.message)


class NotFoundError(AppError):
    def __init__(self, resource: str, identifier: str):
        super().__init__("NOT_FOUND", f"{resource} with id '{identifier}' not found")


class InvalidInputError(AppError):
    def __init__(self, message: str):
        super().__init__("INVALID_INPUT", message)


class ProcessingFailedError(AppError):
    def __init__(self, message: str):
        super().__init__("PROCESSING_FAILED", message)


class TimeoutError(AppError):
    def __init__(self, message: str = "Operation timed out"):
        super().__init__("TIMEOUT", message)


class InternalError(AppError):
    def __init__(self, message: str = "Internal server error"):
        super().__init__("INTERNAL_ERROR", message)

