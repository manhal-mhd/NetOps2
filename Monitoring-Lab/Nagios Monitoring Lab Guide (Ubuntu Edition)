# Nagios Monitoring Lab Guide (Ubuntu Edition)

This guide provides a **step-by-step walkthrough** for setting up a monitoring lab using Nagios 4 on **Ubuntu (20.04 / 22.04 / 24.04)** with Apache and PHP. Explanations are included at each step so you understand both the **configuration** and **reasoning** behind the commands.

> **Note on differences from FreeBSD:** Ubuntu uses `apt` instead of `pkg`, `systemctl` instead of `service`/`rc.conf`, and different default paths. On Ubuntu, the package is called `nagios4`, configs live in `/etc/nagios4/`, plugins in `/usr/lib/nagios/plugins/`, and the web files in `/usr/share/nagios4/htdocs/`.

---

## PART 1: Preparing the Server Before Installing Nagios

### 1.1 Update the System and Install Required Packages

Begin by updating the package index and installing the necessary packages. This includes the Apache web server for delivering the web interface, and PHP for dynamic pages.

```sh
$ sudo apt update
$ sudo apt install apache2
```

> **Why?**
>
> - `apache2` provides the web server that will serve both Nagios and its web interface.
> - On Ubuntu the Apache package is named `apache2` (not `apache24` as on FreeBSD).

> To access your lab's IPv6 environment, set up your browser to use the following HTTP proxy:
> - Proxy IP: `134.209.42.47`
> - Proxy port: `8080`
> - Credentials: `afnog/netops2`
>
> This step is needed if your lab access requires traversing a gateway or firewall.

### 1.2 Install PHP and the Apache PHP Module

Nagios's web interface may use PHP files. On Ubuntu, PHP integration with Apache is handled by the `libapache2-mod-php` package, so there is **no need to manually create a `php.conf` include** as on FreeBSD.

```sh
$ sudo apt install php libapache2-mod-php php-gd
```

> **Why this method?**
>
> - `libapache2-mod-php` automatically installs and enables the PHP handler configuration under `/etc/apache2/mods-enabled/` — Ubuntu's equivalent of the modular include approach.
> - `php-gd` provides graphics support used by some Nagios CGIs (status map, trends).

Verify PHP is enabled:

```sh
$ apache2ctl -M | grep php
```

> You should see something like `php8.3_module (shared)`. If not, enable it manually:
>
> ```sh
> $ sudo a2enmod php8.3
> ```
> (Adjust the version to match `php -v`.)

---

## PART 2: Configure the Apache Web Server

### 2.1 Confirm Configuration Layout

Ubuntu's Apache uses a modular layout by default:

```plaintext
/etc/apache2/
  apache2.conf          ← main config (rarely edited directly)
  ports.conf            ← Listen directives
  sites-available/      ← virtual host definitions
  sites-enabled/        ← enabled vhosts (symlinks)
  conf-available/       ← extra config snippets
  conf-enabled/         ← enabled snippets (symlinks)
  mods-available/       ← module configs
  mods-enabled/         ← enabled modules (symlinks)
```

> Use `a2enmod` / `a2dismod` for modules, `a2enconf` / `a2disconf` for config snippets, and `a2ensite` / `a2dissite` for sites. This is Ubuntu's equivalent of FreeBSD's `Includes/` directory approach.

### 2.2 Configure Apache to Listen on IPv6

Edit `/etc/apache2/ports.conf`:

```sh
$ sudo nano /etc/apache2/ports.conf
```

Find

```
Listen 80
```

and replace (or add) with:

```
Listen [2a02:c207:2054:4961:XXXX::XX]:80
```

> Replace the address with your assigned IPv6 value.
>
> - This instructs Apache to listen for HTTP requests on your IPv6 address, as required in the lab.
> - Note the **square brackets** around the IPv6 address — Apache on Linux requires them.
> - You may keep `Listen 80` alongside the IPv6 stanza if you want local IPv4 access.

Start (and enable) Apache:

```sh
$ sudo systemctl enable --now apache2
```

> `enable --now` both starts the service immediately and configures it to start at boot. Always restart Apache after configuration changes for them to take effect:
>
> ```sh
> $ sudo systemctl restart apache2
> ```

---

## PART 3: Nagios Setup

## Understanding Nagios Structure

Before you begin installation, it's important to understand how Nagios organizes its files and configurations. Nagios is built to be flexible and modular, and its directory layout plays a big role in management.

### Key Components:

- **Core Daemon (`nagios4`):**
  The main Nagios process reads configuration files and runs checks.

- **Configuration Files:**
  - **Main Config (`nagios.cfg`):**
    Sets global options and lists object config files or directories.
  - **Object Configs (`objects/*.cfg` and `conf.d/`):**
    Definitions for hosts, services, contacts, timeperiods, commands, and templates.
  - **Resource Config (`resource.cfg`):**
    Stores user macros, often paths to plugins (`$USER1$` points to the plugin directory).

- **Web Interface (CGI):**
  Allows you to view status and logs in your browser.

- **Plugins:**
  Scripts and binaries that perform the actual checks. Configured via command definitions.

- **Authentication:**
  Access to the web interface is restricted using user accounts (defined in `htpasswd.users`).

### Typical Directory Layout on Ubuntu:

```plaintext
/etc/nagios4/
  nagios.cfg
  resource.cfg
  cgi.cfg
  objects/
    commands.cfg
    contacts.cfg
    localhost.cfg
    templates.cfg
    timeperiods.cfg
    (custom directories, e.g. lab-specific configs)
  conf.d/                            ← extra config dir read by default
  htpasswd.users                     ← you will create this

/usr/share/nagios4/htdocs/           ← Web UI files.
/usr/lib/cgi-bin/nagios4/            ← CGI scripts for web frontend.
/usr/lib/nagios/plugins/             ← Official and custom plugins.
/var/log/nagios4/                    ← Logs (nagios.log is very useful).
```

Nagios's flexibility comes from separating definitions (in `*.cfg` files) from general settings, plugins, and the web interface. You can add your own directories for lab environments and group configurations logically.

---

### 3.1 Install Nagios

```sh
$ sudo apt install nagios4 nagios-plugins-contrib monitoring-plugins
```

> - `nagios4` installs the Nagios monitoring daemon, web interface, and Apache integration (`nagios4-cgi`).
> - `monitoring-plugins` provides the standard checks (`check_http`, `check_dig`, `check_ssh`, etc.).
> - `nagios-plugins-contrib` adds extra community plugins (optional but useful).

Enable Nagios to start automatically at boot:

```sh
$ sudo systemctl enable nagios4
```

> This is Ubuntu's equivalent of FreeBSD's `sysrc nagios_enable="YES"`.

Check which PHP version is installed (already done in Part 1, but confirm):

```sh
$ php -v
```

### 3.2 Nagios Configuration File Structure

Unlike FreeBSD, the Ubuntu package installs configuration files already activated (no `.cfg-sample` renaming needed). Inspect them:

```sh
$ cd /etc/nagios4/
$ ls -l
$ ls -l objects/
```

> **What are these object files for?**
>
> - `commands.cfg`: Defines check commands Nagios can execute.
> - `contacts.cfg`: Specifies people Nagios can notify.
> - `localhost.cfg`: Configuration for the default monitored host (often the local machine).
> - `printer.cfg`, `switch.cfg`: Sample device configs.
> - `templates.cfg`: Defines reusable config templates.
> - `timeperiods.cfg`: Defines periods when checks and notifications are valid.

Confirm the plugin path macro in `/etc/nagios4/resource.cfg`:

```
$USER1$=/usr/lib/nagios/plugins
```

> `$USER1$` is used in command definitions to point at the plugin directory. On Ubuntu this is `/usr/lib/nagios/plugins` (not `/usr/local/libexec/nagios` as on FreeBSD).

---

## PART 4: Use a Custom Objects Directory

Nagios supports object configuration **directories**, so you can organize configurations by lab, environment, etc.

Edit `/etc/nagios4/nagios.cfg` and add:

```
cfg_dir=/etc/nagios4/objects/lab
```

> This tells Nagios to read **all `.cfg` files** inside `objects/lab`.
> (Ubuntu's package already includes `cfg_dir=/etc/nagios4/conf.d` — you could use that directory instead, but creating a dedicated `lab` directory keeps things organized.)

Create the directory:

```sh
$ sudo mkdir -p /etc/nagios4/objects/lab
```

Go into it and create your custom lab config file:

```sh
$ cd /etc/nagios4/objects/lab
$ sudo nano isoc-lab.cfg
```

Paste:

```nagios
# Define DNS check command
define command {
    command_name    check_dig
    command_line    $USER1$/check_dig -H '$HOSTADDRESS$' -l '$ARG1$'
}

# Host for local machine
define host {
    use                     linux-server
    host_name               pcXX.n2.nog-oc.org
    alias                   localhost
    address                 192.168.0.XX
}

define service {
    use                     generic-service
    host_name               pcXX.n2.nog-oc.org
    service_description     DNS Monitor
    check_command           check_dig!pcXX.n2.nog-oc.org
}
```

> **Explanation of Nagios definitions:**
>
> - `define command`: Adds a new Nagios check command (`check_dig`) for DNS monitoring.
> - `define host`: Declares machines to be monitored (`pcXX` and `pcYY` — replace with your values). Note we use the `linux-server` template (defined in `templates.cfg`) instead of FreeBSD's `freebsd-server`.
> - `define service`: Associates a service check (DNS) to a host using the defined command.
>
> **Important:** If `check_dig` is already defined in `/etc/nagios4/objects/commands.cfg`, remove the `define command` block above to avoid a "duplicate definition" error during verification.

You can adapt the above by adding additional services as shown later.

---

## PART 5: Verifying Nagios Configuration

Check configuration syntax before starting Nagios:

```sh
$ sudo nagios4 -v /etc/nagios4/nagios.cfg
```

> Output should end with `Total Errors: 0`.
> Note the binary is `nagios4` on Ubuntu, not `nagios`.

---

## PART 6: Add Nagios Admin User

Nagios's web interface is password protected. Create the admin user ("nagiosadmin") and assign a password:

```sh
$ sudo htpasswd -c /etc/nagios4/htpasswd.users nagiosadmin
```

> - `htpasswd` comes from the `apache2-utils` package (installed automatically with Apache; if missing, run `sudo apt install apache2-utils`).
> - Use the password specified for your class or set your own.
> - The file `htpasswd.users` lists permitted Nagios web users.
> - The `-c` flag creates the file; omit it when adding additional users later.

---

## PART 7: Configure Apache for Nagios (CGI + Auth)

The Ubuntu package installs an Apache snippet at `/etc/apache2/conf-available/nagios4-cgi.conf`, but by default it uses **digest authentication** and IP restrictions. For this lab we will replace it with a simpler **basic authentication** setup consistent with the FreeBSD guide.

First enable the required Apache modules:

```sh
$ sudo a2enmod cgid rewrite auth_basic authz_user
```

Then edit the Nagios Apache configuration:

```sh
$ sudo nano /etc/apache2/conf-available/nagios4-cgi.conf
```

Replace its contents with:

```apache
#============= NAGIOS CONFIGURATION =============

# Filesystem Aliases
ScriptAlias /cgi-bin/nagios4 /usr/lib/cgi-bin/nagios4
ScriptAlias /nagios4/cgi-bin /usr/lib/cgi-bin/nagios4
Alias /nagios4 /usr/share/nagios4/htdocs

# Nagios CGI Interface Authentication
<Directory "/usr/lib/cgi-bin/nagios4">
    Options +ExecCGI
    DirectoryIndex index.php
    AllowOverride None
    AuthType Basic
    AuthName "Nagios Access"
    AuthUserFile /etc/nagios4/htpasswd.users
    Require valid-user
</Directory>

# Nagios Web Interface Authentication and Configuration
<Directory "/usr/share/nagios4/htdocs">
    Options FollowSymLinks
    DirectoryIndex index.php index.html
    AllowOverride None
    AuthType Basic
    AuthName "Nagios Access"
    AuthUserFile /etc/nagios4/htpasswd.users
    Require valid-user
</Directory>
#============= END NAGIOS CONFIGURATION =============
```

> **Explanation:**
>
> - `a2enmod cgid`: Enables execution of CGI programs for Nagios's web interface (Ubuntu picks `cgid` or `cgi` automatically depending on the MPM in use).
> - `<Directory ...>`: Sets up password authentication for the Nagios UI and CGIs.
> - `ScriptAlias`, `Alias`: Map web URLs to directories on disk.
> - PHP handling is already provided globally by `libapache2-mod-php`, so no `<FilesMatch>` blocks are needed here.

Enable the configuration snippet (it is usually enabled automatically at install, but confirm):

```sh
$ sudo a2enconf nagios4-cgi
```

Also make sure CGI authentication is turned on in Nagios itself. In `/etc/nagios4/cgi.cfg`, confirm:

```
use_authentication=1
authorized_for_all_hosts=nagiosadmin
authorized_for_all_services=nagiosadmin
authorized_for_system_information=nagiosadmin
authorized_for_configuration_information=nagiosadmin
authorized_for_all_host_commands=nagiosadmin
authorized_for_all_service_commands=nagiosadmin
authorized_for_system_commands=nagiosadmin
```

> This grants the `nagiosadmin` web user full visibility of all hosts and services. Without it, you can log in but see an empty dashboard.

---

## PART 8: Final Steps & Verification

### 8.1 Check Apache Syntax

Always check your Apache configuration before restarting:

```sh
$ sudo apache2ctl configtest
```

> If syntax is OK, you'll see `Syntax OK`.

### 8.2 Add the Web Server User to the Nagios Group

To allow Apache's CGIs to read Nagios's status files and command pipe:

```sh
$ sudo usermod -aG nagios www-data
```

> On Ubuntu the web server runs as `www-data` (not `www` as on FreeBSD), and the Nagios daemon runs as user/group `nagios`.

### 8.3 Start Services

```sh
$ sudo systemctl restart nagios4
$ sudo systemctl restart apache2
```

Check both are running:

```sh
$ systemctl status nagios4 apache2
```

### 8.4 Verify Configuration One Last Time

```sh
$ sudo nagios4 -v /etc/nagios4/nagios.cfg
```

Should report `Total Errors: 0`.

---

## PART 9: Access Nagios Web Interface

Open your browser and go to:

```
http://[2a02:c207:2054:4961:aaaa::XX]/nagios4/
```

- Use the **username:** `nagiosadmin`
- Use your previously set **password**

You will see the Nagios dashboard if setup is correct.

> Note the URL path is `/nagios4/` on Ubuntu (matching the package name), not `/nagios/`.

---

## PART 10: Adding More Services

To monitor additional services (CPU, memory, HTTP, etc.), add more `define service` blocks to your lab config file:

```sh
$ sudo nano /etc/nagios4/objects/lab/isoc-lab.cfg
```

```nagios
# Host for partner server
define host {
    use                     linux-server
    host_name               pcYY.n2.nog-oc.org
    alias                   Partner Zone
    address                 192.168.0.YY
}

define service {
    use                     generic-service
    host_name               pcYY.n2.nog-oc.org
    service_description     DNS Monitor
    check_command           check_dig!pcYY.n2.nog-oc.org
}

# Example: monitor HTTP service on pcYY
define service {
    use                     generic-service
    host_name               pcYY.n2.nog-oc.org
    service_description     HTTP Monitor
    check_command           check_http
}
```

After editing, always check and restart:

```sh
$ sudo nagios4 -v /etc/nagios4/nagios.cfg
$ sudo systemctl restart nagios4
```

> All services you define and assign to hosts will appear in the web interface.

---

## Troubleshooting Tips

- **Nagios fails to start:** Double-check config syntax with `sudo nagios4 -v /etc/nagios4/nagios.cfg`, and inspect logs with `sudo journalctl -u nagios4` or `/var/log/nagios4/nagios.log`.
- **Apache not serving Nagios:** Ensure the `nagios4-cgi` conf is enabled (`sudo a2enconf nagios4-cgi`), aliases are correct, and CGI is enabled (`sudo a2enmod cgid`).
- **Forbidden or authentication errors:** Make sure `/etc/nagios4/htpasswd.users` exists, the password is set for `nagiosadmin`, and `AuthUserFile` points to it. Also confirm `use_authentication=1` in `cgi.cfg`.
- **Logged in but dashboard empty:** Check the `authorized_for_*` lines in `/etc/nagios4/cgi.cfg` include `nagiosadmin`.
- **"Could not open command file" errors:** Verify `www-data` is in the `nagios` group (`groups www-data`) and restart Apache after adding it.
- **No services appear:** Verify your `cfg_dir` is set in `nagios.cfg`, and object definitions are valid.
- **check_dig not found:** Install `monitoring-plugins-standard` (`sudo apt install monitoring-plugins-standard`) which provides DNS-related checks.
- **Proxy/Browser issues:** Ensure the proxy credentials and settings are correctly entered if remote IPv6 access is required.

---

## Assignment Submission

> **Submit a screenshot of your Nagios services page showing all OK/green statuses in the service grid.**

---

## Quick Reference: Common Nagios Configuration Sections

- **Commands (`commands.cfg` or `isoc-lab.cfg`):**
  ```nagios
  define command {
      command_name    some_check
      command_line    /usr/lib/nagios/plugins/some_plugin $ARG1$
  }
  ```
- **Hosts (`localhost.cfg` or `isoc-lab.cfg`):**
  ```nagios
  define host {
      use         generic-host
      host_name   example
      address     192.168.1.10
  }
  ```
- **Services (`localhost.cfg` or `isoc-lab.cfg`):**
  ```nagios
  define service {
      use                     generic-service
      host_name               example
      service_description     HTTP
      check_command           check_http
  }
  ```
- **Contacts (`contacts.cfg`):**
  ```nagios
  define contact {
      contact_name        admin
      email              admin@example.com
  }
  ```

---

## FreeBSD → Ubuntu Cheat Sheet

| Task | FreeBSD | Ubuntu |
|---|---|---|
| Install package | `pkg install nagios` | `sudo apt install nagios4` |
| Enable at boot | `sysrc nagios_enable="YES"` | `sudo systemctl enable nagios4` |
| Start service | `service nagios start` | `sudo systemctl start nagios4` |
| Main config | `/usr/local/etc/nagios/nagios.cfg` | `/etc/nagios4/nagios.cfg` |
| Plugins | `/usr/local/libexec/nagios/` | `/usr/lib/nagios/plugins/` |
| Web files | `/usr/local/www/nagios/` | `/usr/share/nagios4/htdocs/` |
| Apache config | `/usr/local/etc/apache24/` | `/etc/apache2/` |
| Apache syntax check | `apachectl -t` | `sudo apache2ctl configtest` |
| Web server user | `www` | `www-data` |
| Verify config | `nagios -v ...` | `sudo nagios4 -v ...` |
| Editor | `ee` | `nano` |
| Web URL | `/nagios/` | `/nagios4/` |

---

**Understanding what each configuration does allows you to adapt Nagios to monitor any server or service you need — for the lab and future work. Good luck!**
