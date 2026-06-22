# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Flutter SDK + Build
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_VERSION=3.44.2 \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PATH="/opt/flutter/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        unzip \
        xz-utils \
        zip \
        libglu1-mesa \
        openjdk-17-jdk \
        wget \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Flutter SDK ───────────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} \
        https://github.com/flutter/flutter.git ${FLUTTER_HOME}

# Pre-cache Dart SDK and tool artifacts
RUN flutter precache --android --no-ios --no-web --no-linux --no-windows --no-macos \
    && flutter config --no-analytics \
    && flutter doctor --android-licenses || true

# ── Android SDK ───────────────────────────────────────────────────────────────
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
         -O /tmp/cmdline-tools.zip \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-tmp \
    && mv /tmp/cmdline-tools-tmp/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
    && rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-tmp

# Accept SDK licences and install required SDK components
RUN yes | sdkmanager --licenses \
    && sdkmanager \
        "platforms;android-34" \
        "build-tools;34.0.0" \
        "platform-tools"

# ── App build ─────────────────────────────────────────────────────────────────
WORKDIR /app

# Copy Flutter project files
COPY . .

# Fetch pub dependencies
RUN flutter pub get

# Build a release APK (unsigned – suitable for testing; sign separately for prod)
RUN flutter build apk --release \
        --dart-define=FLUTTER_BUILD_MODE=release

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Artifact image
#   A tiny image that holds only the built APK so it can be extracted with
#   `docker cp` or bind-mounted for distribution.
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.19

WORKDIR /output

COPY --from=builder /app/build/app/outputs/flutter-apk/app-release.apk ./component_detection.apk

# Default command prints the APK location – useful as a reminder
CMD ["sh", "-c", "echo '✅ APK ready at /output/component_detection.apk'"]
