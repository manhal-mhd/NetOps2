# Nagios Monitoring Lab Guide

This guide provides a **step-by-step walkthrough** for setting up a monitoring lab using Nagios on FreeBSD with Apache and PHP. Explanations are included at each step so you understand both the **configuration** and **reasoning** behind the commands.

---

## PART 1: Preparing the Server Before Installing Nagios

### 1.1 Install Required Packages

Begin by installing the necessary packages for your monitoring setup. This includes the Apache web server for delivering the web interface, and PHP for dynamic pages.

```sh
# pkg install apache24
```

> **Why?**
>
> - `apache24` provides the web server that will serve both Nagios and its web interface.

> To access your lab's IPv6 environment, set up your browser to use the following HTTP proxy:
> - Proxy IP: `134.209.42.47`
> - Proxy port: `8080`
> - Credentials: `afnog/netops2`
> 
> This step is needed if your lab access requires traversing a gateway or firewall.

### 1.2 PHP Configuration – Recommended Modular Approach

Nagios's web interface may use PHP files. **Recommended:** use a modular Apache configuration by placing PHP settings in an include file.

Create `/usr/local/etc/apache24/Includes/php.conf`:

```sh
# ee /usr/local/etc/apache24/Includes/php.conf
```

Add:

```apache
<IfModule dir_module>
    DirectoryIndex index.php index.html
    <FilesMatch "\.php$">
        SetHandler application/x-httpd-php
    </FilesMatch>
    <FilesMatch "\.phps$">
        SetHandler application/x-httpd-php-source
    </FilesMatch>
</IfModule>
```

> **Why this method?**
>
> - Keeps your Apache configuration modular and maintainable.
> - Avoids editing the main `httpd.conf` for every software package.

*You do not need to add these `<FilesMatch>` directives directly to `httpd.conf` if using this include file.*

If you use `csh` as your shell, run:

```sh
# rehash
```
> This reloads your shell environment so new commands/packages are available.  
> _Not required in Bash._

---

## PART 2: Configure the Apache Web Server

### 2.1 Confirm PHP Include

Make sure Apache includes your PHP configuration file. By default, it loads all files under `/usr/local/etc/apache24/Includes/`. No changes to `httpd.conf` should be needed unless includes are disabled.

### 2.2 Configure Apache to Listen on IPv6

Edit `/usr/local/etc/apache24/httpd.conf`:

Find
```
Listen 80
```
and replace (or add) with:
```
Listen 2a02:c207:2054:4961:XXXX::XX:80
```
> Replace the address with your assigned IPv6 value.
>
> - This instructs Apache to listen to HTTP requests on your IPv6 address, as required in the lab.
> - You may keep `Listen 80` alongside the IPv6 stanza if you want local IPv4 access.

Start Apache:

```sh
# service apache24 start
```
> Always start/restart Apache after configuration changes for them to take effect.

---

## PART 3: Nagios Setup
## Understanding Nagios Structure

Before you begin installation, it's important to understand how Nagios organizes its files and configurations. Nagios is built to be flexible and modular, and its directory layout plays a big role in management.

### Key Components:

- **Core Daemon (`nagios`):**  
  The main Nagios process reads configuration files and runs checks.

- **Configuration Files:**
  - **Main Config (`nagios.cfg`):**  
    Sets global options and lists object config files or directories.
  - **Object Configs (`objects/*.cfg`):**  
    Definitions for hosts, services, contacts, timeperiods, commands, and templates.
  - **Resource Config (`resource.cfg`):**  
    Stores user macros, often paths to plugins.

- **Web Interface (CGI):**  
  Allows you to view status and logs in your browser, usually at `/usr/local/www/nagios/` and `/usr/local/www/nagios/cgi-bin`.

- **Plugins:**  
  Scripts and binaries that perform the actual checks, located in `/usr/local/libexec/nagios/`. Configured via command definitions.

- **Authentication:**  
  Access to the web interface is restricted using user accounts (defined in `htpasswd.users`).

### Typical Directory Layout:

```plaintext
/usr/local/etc/nagios/
  nagios.cfg
  resource.cfg
  cgi.cfg
  objects/
    commands.cfg
    contacts.cfg
    hosts.cfg
    services.cfg
    templates.cfg
    (custom directories, e.g. lab-specific configs)
  htpasswd.users

/usr/local/www/nagios/               ← Web UI files.
      cgi-bin/                       ← CGI scripts for web frontend.

 /usr/local/libexec/nagios/          ← Official and custom plugins.
```

Nagios's flexibility comes from separating definitions (in *.cfg files) from general settings, plugins, and the web interface. You can add your own directories for lab environments, group configuratio[...]

---

### 3.1 Install Nagios

```sh
# pkg install nagios
```
> Installs the Nagios monitoring tool and its dependencies.

Enable Nagios to start automatically at boot in `/etc/rc.conf`:

```sh
nagios_enable="YES"
```
Or use the tool:

```sh
# sysrc nagios_enable="YES"
```

**Nagios requires PHP. Check which PHP version is installed:**

```sh
php -v
```

Then install the matching PHP Apache modules:

```sh
# pkg install mod_php84 php84-xml
```
> Adjust `84` to match your PHP version (e.g., `mod_php80` for PHP 8.0).

### 3.2 Configure Nagios File Structure

Nagios uses a number of configuration files (with `.cfg-sample` suffix by default) which you'll need to rename to `.cfg` to activate.

```sh
# cd /usr/local/etc/nagios/
# for f in *.cfg-sample; do cp "$f" "${f%-sample}"; done
```

In the objects subdirectory, rename all sample object configuration files:

```sh
# cd objects/
# for f in *.cfg-sample; do cp "$f" "${f%-sample}"; done
```

> **What are these object files for?**
>
> - `commands.cfg`: Defines check commands Nagios can execute.
> - `contacts.cfg`: Specifies people Nagios can notify.
> - `localhost.cfg`: Configuration for the default monitored host (often the local machine).
> - `printer.cfg`, `switch.cfg`: Sample device configs.
> - `templates.cfg`: Defines reusable config templates.
> - `timeperiods.cfg`: Defines periods when checks and notifications are valid.

Confirm renaming worked:

```sh
# ls -l
```

---

## PART 4: Use a Custom Objects Directory

Nagios supports object configuration **directories**, so you can organize configurations by lab, environment, etc.

Edit `/usr/local/etc/nagios/nagios.cfg` and add:

```
cfg_dir=/usr/local/etc/nagios/objects/lab
```
> This tells Nagios to read **all `.cfg` files** inside `objects/lab`.

Create the directory:

```sh
# mkdir -p /usr/local/etc/nagios/objects/lab
```
Go into it and create your custom lab config file:

```sh
# cd /usr/local/etc/nagios/objects/lab
# ee isoc-lab.cfg
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
    use                     freebsd-server
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
> - `define host`: Declares machines to be monitored (`pcXX` and `pcYY` – replace with your values).
> - `define service`: Associates a service check (DNS) to a host using the defined command.

You can adapt the above by adding additional services as shown below.

---

## PART 5: Verifying Nagios Configuration

Check configuration syntax before starting Nagios:

```sh
# nagios -v /usr/local/etc/nagios/nagios.cfg
```
> Output should end with `Total Errors: 0`.

---

## PART 6: Add Nagios Admin User

Nagios's web interface is password protected. Create the admin user ("nagiosadmin") and assign a password:

```sh
# htpasswd -c /usr/local/etc/nagios/htpasswd.users nagiosadmin
```

> - Use the password specified for your class or set your own.
> - The file `htpasswd.users` lists permitted Nagios web users.

---

## PART 7: Configure Apache for Nagios (CGI + Auth)

Create a dedicated config for Nagios:

```sh
# ee /usr/local/etc/apache24/Includes/nagios.conf
```

Paste:

```apache
#============= NAGIOS CONFIGURATION =============
# CGI is required for Nagios's web interface; ensure these modules are present:

# CGI Module Loading
<IfModule !mpm_prefork_module>
    LoadModule cgid_module libexec/apache24/mod_cgid.so
</IfModule>
<IfModule mpm_prefork_module>
    LoadModule cgi_module libexec/apache24/mod_cgi.so
</IfModule>

# PHP Configuration
<FilesMatch "\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
<FilesMatch "\.phps$">
    SetHandler application/x-httpd-php-source
</FilesMatch>

# Nagios Web Interface Authentication and Configuration
<Location /nagios>
    AuthType Basic
    AuthName "Nagios Access"
    AuthUserFile /usr/local/etc/nagios/htpasswd.users
    Require valid-user
    php_flag engine on
    php_admin_value open_basedir "/usr/local/www/nagios/:/var/spool/nagios/"
</Location>

# Nagios CGI Interface Authentication
<Location /nagios/cgi-bin>
    AuthType Basic
    AuthName "Nagios Access"
    AuthUserFile /usr/local/etc/nagios/htpasswd.users
    Require valid-user
    Options ExecCGI
</Location>

# Filesystem Aliases
ScriptAlias /nagios/cgi-bin/ /usr/local/www/nagios/cgi-bin/
Alias /nagios/ /usr/local/www/nagios/

<Directory "/usr/local/www/nagios">
    AllowOverride None
    Require all granted
</Directory>

<Directory "/usr/local/www/nagios/cgi-bin">
    AllowOverride None
    Require all granted
    Options ExecCGI
</Directory>
#============= END NAGIOS CONFIGURATION =============
```

> **Explanation:**
>
> - CGI modules: Enable the execution of CGI programs for Nagios's web interface.
> - `<FilesMatch ...>`: Ensures PHP is used where needed.
> - `<Location /nagios>`: Sets up password authentication for the Nagios UI.
> - `ScriptAlias`, `Alias`: Maps web URLs to directories on disk.

---

## PART 8: Final Steps & Verification

### 8.1 Check Apache Syntax

Always check your Apache configuration before restarting:

```sh
# apachectl -t
```

> If syntax is OK, you'll see `Syntax OK`.

### 8.2 Add Nagios User to Apache Group

To allow Nagios to interact with the web directories:

```sh
# pw usermod nagios -G www
```

### 8.3 Start Services

```sh
# service nagios start
# service apache24 restart
```

### 8.4 Verify Configuration One Last Time

```sh
# nagios -v /usr/local/etc/nagios/nagios.cfg
```

Should report `Total Errors: 0`.

---

## PART 9: Access Nagios Web Interface

Open your browser and go to:

```
http://[2a02:c207:2054:4961:aaaa::XX]/nagios/
```
- Use the **username:** `nagiosadmin`
- Use your previously set **password**

You will see the Nagios dashboard if setup is correct.

---

## PART 10: Adding More Services

To monitor additional services (CPU, memory, HTTP, etc.), add more `define service` blocks to your lab config file:

```sh
# ee /usr/local/etc/nagios/objects/lab/isoc-lab.cfg

# Host for partner server
define host {
    use                     freebsd-server
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
# nagios -v /usr/local/etc/nagios/nagios.cfg
# service nagios restart
```

> All services you define and assign to hosts will appear in the web interface.

---

## Troubleshooting Tips

- **Nagios fails to start:** Double-check config syntax with `nagios -v`.
- **Apache not serving Nagios:** Ensure aliases are correct and permissions are set.
- **Forbidden or authentication errors:** Make sure `htpasswd.users` exists and password is set for `nagiosadmin`.
- **No services appear:** Verify your `cfg_dir` is set, and object definitions are valid.
- **Proxy/Browser issues:** Ensure the proxy credentials and settings are correctly entered if remote IPv6 access is required.

---

## Assignment Submission

> **Submit a screenshot of your Nagios services page showing all OK/green statuses in the service grid.**

---

## Quick Reference: Common Nagios Configuration Sections

- **Commands (`commands.cfg` or `iso-lab.cfg`):**
  ```nagios
  define command {
      command_name    some_check
      command_line    /path/to/plugin $ARG1$
  }
  ```
- **Hosts (`localhost.cfg` or `iso-lab.cfg`):**
  ```nagios
  define host {
      use         generic-host
      host_name   example
      address     192.168.1.10
  }
  ```
- **Services (`localhost.cfg` or `iso-lab.cfg`):**
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

**Understanding what each configuration does allows you to adapt Nagios to monitor any server or service you need – for the lab and future work. Good luck!**
