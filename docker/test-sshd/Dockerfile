FROM alpine:3.19

RUN apk add --no-cache openssh-server bash tmux \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash testuser \
 && echo 'testuser:testpass' | chpasswd \
 && mkdir -p /home/testuser/.ssh \
 && chmod 700 /home/testuser/.ssh

# Allow password auth (for the password credential test path)
RUN sed -i 's/^#PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config \
 && echo 'AllowTcpForwarding no' >> /etc/ssh/sshd_config \
 && echo 'X11Forwarding no' >> /etc/ssh/sshd_config

COPY testuser_id_ed25519.pub /home/testuser/.ssh/authorized_keys
RUN chmod 600 /home/testuser/.ssh/authorized_keys \
 && chown -R testuser:testuser /home/testuser/.ssh

# tmux config: mouse mode on (required for SGR scroll wheel events)
RUN printf 'set -g mouse on\nset -g history-limit 5000\n' \
 > /home/testuser/.tmux.conf \
 && chown testuser:testuser /home/testuser/.tmux.conf

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
