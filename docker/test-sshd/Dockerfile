FROM alpine:3.19

RUN apk add --no-cache openssh-server bash tmux \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash testuser \
 && echo 'testuser:testpass' | chpasswd \
 && mkdir -p /home/testuser/.ssh \
 && chmod 700 /home/testuser/.ssh

# Allow password auth (for the password credential test path)
# AllowTcpForwarding=local (#1047): the ssh -L integration test needs the
# server to accept direct-tcpip channels. `local` permits ONLY local
# forwarding — remote (-R) stays blocked, matching the app's v1 scope.
# NOTE: Alpine's stock sshd_config ships an UNCOMMENTED `AllowTcpForwarding no`
# and sshd honours the FIRST occurrence — an appended line is dead config, so
# replace the existing directive in place.
RUN sed -i 's/^#PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config \
 && sed -i 's/^AllowTcpForwarding .*/AllowTcpForwarding local/' /etc/ssh/sshd_config \
 && echo 'X11Forwarding no' >> /etc/ssh/sshd_config

COPY testuser_id_ed25519.pub /home/testuser/.ssh/authorized_keys
RUN chmod 600 /home/testuser/.ssh/authorized_keys \
 && chown -R testuser:testuser /home/testuser/.ssh

# tmux config: mouse mode on (required for SGR scroll wheel events)
RUN printf 'set -g mouse on\nset -g history-limit 5000\n' \
 > /home/testuser/.tmux.conf \
 && chown testuser:testuser /home/testuser/.tmux.conf

# Deterministic Claude-Code-like TUI painter for the golden-flow emulator test
# (box-drawing, forced margins, wrapped URL, streaming lines with interior
# spaces). See fake-tui.sh header.
COPY fake-tui.sh /usr/local/bin/fake-tui
RUN chmod 755 /usr/local/bin/fake-tui

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
