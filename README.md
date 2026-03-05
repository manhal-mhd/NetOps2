# NetOps Soft Skills Guide for System Engineers

This guide provides recommendations and daily practices for system engineers managing internet services such as web servers, mail servers, monitoring, and DNS authentication. It covers essential habits and troubleshooting techniques that improve efficiency, reduce errors, and foster professional growth.

---

## General Daily Soft Skills

### 1. Validate Before You Act
- **Always check configuration syntax** before restarting or reloading any service. Use built-in syntax checkers:
  - For Nginx: `nginx -t`
  - For Apache: `apachectl configtest`
  - For Postfix: `postfix check`
  - For BIND DNS: `named-checkconf` and `named-checkzone`
- **Review logs** (`/var/log/`) after making any change to ensure normal operation.

### 2. Controlled Service Management
- **Restart or reload services after editing configuration files.**
  - Use `systemctl restart <service>` or `systemctl reload <service>`
  - Always confirm service status: `systemctl status <service>`
- **Announce downtime** if changes may impact users. Communicate clearly with stakeholders.

### 3. Track Configuration Changes
- **Version control your `/etc` directory** with a tool like [`etckeeper`](https://etckeeper.branchable.com/).
  - Enables change tracking, rollback, and audit trails.
  - Document all significant changes in commit messages.

### 4. Document Everything
- **Maintain a changelog** for your services and systems. Include:
  - Date and nature of changes
  - Reason for changes
  - Person responsible
  - Any issues found and resolutions

- **Write procedural runbooks** for repeating tasks (e.g., adding DNS records, configuring email filtering).
  - Make documentation accessible to the team.

### 5. Backups and Recovery
- **Automate regular backups** for config files, mail data, DNS zones, and monitoring configurations.
- **Test recovery procedures** regularly—know how to restore quickly.

### 6. Proactive Monitoring
- **Monitor services** using tools like `Nagios`, `Zabbix`, or `Prometheus`.
- **Set up alerts** for abnormal behavior, resource exhaustion, or failed services.
- **Regularly review monitoring dashboards** for trends and anomalies.

### 7. Troubleshooting Mindset
- **Gather comprehensive information** before action: check logs, configs, recent changes, network status.
- **Formulate a hypothesis, test, and document results.**
- **Use diff tools** (`diff`, `git`, `etckeeper`) to compare current and previous configurations.

### 8. Security Awareness
- **Apply least privilege** when managing accounts and permissions.
- **Rotate passwords and keys**
- **Regularly update packages and patch vulnerabilities.**
- **Enable audit logging** on critical systems.

---

## Recommended Daily Workflow

1. **Start of day:** Review monitoring alerts and overnight logs.
2. **Before change:** Backup configuration, run syntax checks, plan rollback steps.
3. **During change:** Notify stakeholders, document each step.
4. **After change:** Test service, monitor for issues, commit changes to version control, document results.
5. **End of day:** Summarize changes and incidents for team review.

---

## Additional Recommendations

- **Communicate clearly and often**—with your team, end-users, and management.
- **Stay organized**—use ticketing systems and documentation repositories.
- **Keep learning**—dedicate time for reading documentation, blog posts, or engaging in peer review.
- **Be prepared for incidents**—know your escalation paths and emergency contacts.

---

## Useful Tools

- **Service Syntax Checkers**: `nginx`, `apachectl`, `postfix`, `named-checkconf`, `named-checkzone`
- **Service Management**: `systemctl`, `service`
- **Change Tracking**: `etckeeper`, `git`
- **Monitoring**: `Nagios`, `Zabbix`, `Prometheus`
- **Backup**: `rsync`, `bacula`, `borgbackup`

---

_This guide is a living document—feel free to customize and expand as your team's needs evolve._

