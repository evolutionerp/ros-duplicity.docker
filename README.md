# Duplicity for Rancher OS

Rancher OS (/Docker) backup and restore through Duplicity, with custom
strategies, cron jobs, no downtime (during backup only), and more.

### :warning: Experimental release
Functions to be added:

* E-mail notifications once an operation is finished
* Backup and restore of images and stacks (/docker-compose.yml)
* Functions in configuration to be called before an operation starts, and after
  an operation is completed (successfully or unsuccessfully)
* Handling cancellation events (CTRL+C via exec, etc.)

## 1. Integration with RancherOS

Merge the following snippet with your **cloud-config.yml**:

```yaml
#cloud-config
write_files:
  # ros-duplicity.conf
  - path: /opt/ros-duplicity/conf/ros-duplicity.conf
    permissions: "0600"
    owner: root
    content: |
      #!/bin/false
      #<< Paste your configuration after this line. See chapter 2 for more. >>
rancher:
  services:
    ros-duplicity:
      image: evolutionsrl/ros-duplicity
      hostname: 'example.com' # <- Replace with your actual hostname
      labels:
      - io.rancher.os.scope=system
      volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/ros-duplicity/conf:/conf
```

## 2. Configuration

All the configuration should reside in the **conf/ros-duplicity.conf** file,
initialized above. It's sourced inside **bash**, so make sure it's well
protected (better to `chown root:root` and `chmod 600` the whole configuration
directory).

### `cron_add`
Add a backup schedule.

```html
cron_add <cron-time> [<mode ="backup">]
```

* This directive is parsed ONLY when the container starts (daemon mode).
* If a custom mode is not specified, `manual` is implied.
  See chapter 4 for more information about modes.

### `duplicity_target`
Add an output target for duplicity.

```html
duplicity_target [[-E <var> <value>]] <url-to-target> [[<options>]]
```

  * Use **-E** to declare environment variables that will be passed to duplicity.
  * Specify the URL to the target before (optional) duplicity options.

> Invoke twice or more for multiple output targets.

### `gpg_key`
Define a GPG key (to be used by duplicity for encryption).

```sh
gpg_key << end_key
<key-data>
end_key
```

* Export your local key data with `gpg2 --export-secret-keys --armor`. For more
  detailed informations, see [`man gpg2`](https://linux.die.net/man/1/gpg2).
* Keys defined here are automatically trusted. Another reason to secure your
  configuration file as much as you can.

### `strategy_add`
Define a backup strategy.

Containers and images can make use of this strategy by simply having a label
(`it.evolution.bk.strategy`) set with the strategy name.

```html
strategy_add <name> <function-ref>
```

  * Specify an unique name for the backup strategy. If defined twice, the
    strategy will be overridden.
  * Declare a function **BEFORE** adding the strategy, then pass the function
    name as second parameter.
  * For better isolation, strategy functions are run inside
    [bash subshells](http://tldp.org/LDP/abs/html/subshells.html).
  
**Example:**

```sh
_s_myStrategy() {
  if [ "$BK_LOCAL_OUTPUT" ]; then
    true # <-- Replace with backup code
  elif [ "$BK_LOCAL_INPUT" ]; then
    true # <-- Replace with restore code
  fi
}
strategy_add 'my_strategy' _s_myStrategy
```

### `strategy_for_image`
Use the same strategy for all containers based on a specific image (NOT
derivatives of that image)

```html
strategy_for_image <image> <name>|-
```

 * Pass a single hyphen (`-`) instead of a strategy name to resort to the
   default strategy.
 
**Example:**

```sh
strategy_for_image 'evolutionsrl/backbone' 'my_strategy'
```

### `strategy_for_container`
Use the specified strategy for the container whose name or ID is passed.

```html
strategy_for_container <container> <name>
```

* Pass a single hyphen (`-`) instead of a strategy name to resort to the default
  strategy.
 
**Example:**

```sh
strategy_for_container 'evolution-backbone' 'my_strategy'
```

## 3. Strategies
When defining a strategy function, you can access the following variables:

* `$BK_CONTAINER`: The container name that is being processed
* `$BK_CONTAINER_ALIAS`: The container name that is targeted by the current
  container (see chapter 6).
* `$BK_CONTAINER_IMAGE`: The image this container was build upon.
* `$BK_LOCAL_INPUT`: Local (extra-container) path where the backed-up files are
  located, or empty when not restoring.
* `$BK_LOCAL_OUTPUT`: Local (extra-container) path where target file should be
  stored, or empty when restoring.
* `$BK_MODE`: The mode in use. Please see chapter 4 for more information.

> **Important**: Please use `[ -n "$BK_LOCAL_INPUT" ]` as a test for restore
> condition, or `[ -n "$BK_LOCAL_OUTPUT" ]` for backup, instead.

And the following functions:

### `bk_env`
Enumerates the environment variables, or read a specific variable, declared for
the container.

```html
bk-env [<var>]
```

### `bk_pull`
Pull a file or directory from within the container.

```html
bk_pull <internal-path> [<external-path>]
```

* If no external path is provided, and a file is pointed, the content is printed
  to STDOUT.
* If no external path is provided, and a directory is pointed, the (recursive)
  inner paths of the directory are printed to STDOUT.

### `bk_push`
Push a file or directory into the container.

```html
bk_push <external-path> <internal-path>
```

### `bk_strategy`
Invoke another strategy.

```html
bk_strategy <name>|-
```

 * Pass a single hyphen (`-`) instead of a strategy name to invoke the default
   strategy.
 
### `bk_volumes`
Enumerates the internal volume paths declared for the container, one per line.

```html
bk_volumes
```

* Use **bk-pull** or **bk-push** to read from or write to the volume space.
* Volumes can be excluded via the `it.evolution.bk.volumes.exclude` label.
  For more information, see chapter 6.

## 4. Modes
Backup modes can be used to specify alternate configurations. While defining
strategy functions or even the main configuration file, you can use the
`$BK_MODE` variable to switch from different behaviours.

Modes can be specified for `cron_add` instructions (see chapter 2), but also
when performing manual operations from the command line (see chapter 5). If the
backup container is run in default/daemon mode, the initial backup and initial
restore use the predefined `auto` mode.

**Example**:

You can for instance define a more thorough backup once a week
(with two targets), and a regular backup (to a single target) like this:

```sh
#!/bin/false
# ros-backup.conf
cron-add '0 3 * * *' daily # Once a day (everyday, 3:00am)
cron-add '0 2 * * 0' weekly # Once a week (every Sunday, 2:00am)

# duplicity-target [...]

# [...]

# Secondary target, only for weekly-backup mode
if [ "$BK_MODE" = "weekly-backup" ]; then
    duplicity-target 'sftp://uid:password@other.host/some_dir' full
fi
```

## 5. Manual operations

It's possible to invoke manual backups by executing, on the host:

```html
sudo system-docker exec -it ros-duplicity backup [[<args>]]
```

Or, for manual restores:

```html
sudo system-docker exec -it ros-duplicity restore [[<args>]]
```

Supported optional `[[<args>]]` are:

* `-d, --duplicity-arg <<args>>` to pass one or more arguments to the underlying
  **duplicity** processes (all targets are affected).
* `-D, --duplicity-env <<var>=<value>>` to pass a environment variables to
  the underlying **duplicity** processes (all targets are affected).
* `-i, --include <container>` to use inclusion policy (only specified containers
  are to be affected by the operation). Doesn't work with `-e, --exclude`.
* `-e, --exclude <container>` to use exclusion policy (all but specified
  containers are affected by the operation). Doesn't work with `-i, --include`.
* `--cron` to treat the operation as automatic / scheduled (future usage).
* `--debug` to turn on diagnostic messages in the operation log.

> Multiple values can be passed to these options by surrounding them with a
> leading `{ ` and a trailing ` }` pseudo-arguments. For instance:
> 
> ```sh
> -i { container1 container2 container3 }
> ```
>
> :warning: The spaces after `{ ` and before ` }` are critically important!
>

## 6. Labels

It's possible to override default behaviour for specific containers or images by
specifying the following labels:


<table>
  <thead>
    <tr>
      <th>Label</th>
      <th>Value syntax</th>
      <th>Default</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>it.evolution.bk.alias</code></td>
      <td>&lt;string&gt;</td>
      <td><code>/var/run/docker.sock:</code></td>
      <td>
      Define an <b>alias</b>; this will make all images/containers having
      the same alias or name collide within the same backup space. It's useful,
      for instance, to make docker-compose containers (whose name are dynamic
      and similar to `dir_mycontainer_1`) backup/restore using a different and
      static name (e.g. `mycontainer`).
      </td>
    </tr>
    <tr>
      <td><code>it.evolution.bk.skip</code></td>
      <td>&lt;bool&gt;</td>
      <td><code>false</code></td>
      <td>Exclude the present container or image from all operations</td>
    </tr>
    <tr>
      <td><code>it.evolution.bk.strategy</code></td>
      <td>&lt;string&gt;</td>
      <td><code>-</code></td>
      <td>Strategy to use for backup and restore operations</td>
    </tr>
    <tr>
      <td><code>it.evolution.bk.volumes.exclude</code></td>
      <td>&lt;list[:]&gt;</td>
      <td><code>/var/run/docker.sock:</code></td>
      <td>Exclude specific volumes from <code>bk_volumes</code> calls</td>
    </tr>
  </tbody>
</table>