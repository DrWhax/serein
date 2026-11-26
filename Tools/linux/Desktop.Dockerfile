# Stage the application and worker products with build-desktop.sh first.
ARG SEREIN_TOOLCHAIN=serein-toolchain
FROM ${SEREIN_TOOLCHAIN} AS desktop
RUN apt-get update && apt-get install -y --no-install-recommends \
        dbus-daemon gnome-keyring polkitd qt6-qpa-plugins qt6-xdgdesktopportal-platformtheme \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --home-dir /var/lib/serein --shell /usr/sbin/nologin serein \
    && install -d -m 0700 -o serein -g serein /run/serein /var/lib/serein
COPY bin/ /opt/serein/bin/
COPY share/ /opt/serein/share/
COPY share/icons/ /usr/share/icons/
COPY serein-session.py /opt/serein/serein-session.py
COPY org.signalsafe.SignalSafe.policy /usr/share/polkit-1/actions/
COPY org.signalsafe.SignalSafe.desktop /usr/share/applications/
ENV HOME=/var/lib/serein XDG_RUNTIME_DIR=/run/serein
USER serein
ENTRYPOINT ["python3", "/opt/serein/serein-session.py"]

# Test tools run outside the application process and its confinement domain.
FROM desktop AS capture
USER root
RUN apt-get update && apt-get install -y --no-install-recommends xvfb xauth xdotool python3-pil \
    && rm -rf /var/lib/apt/lists/*
USER serein
