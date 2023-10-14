---
title: "Containerizing an App for Kubernetes"
name: Endoze
date: 2023-10-11 13:21:03 -0400
tags: Kubernetes ruby docker
---

Getting started with Kubernetes can be daunting. If you're setting up your first
cluster, you've got your work cut out for you. The choices of log gathering,
metrics collectors, ingress controllers, and even cloud hosts can make the work
to containerize your apps seem less important. But once you get down to it,
containerizing your applications for operation within your cluster is just as
important.

## Requirements

You will need to install the [docker cli client](https://github.com/docker/cli),
[a container runtime](https://github.com/abiosoft/colima), and
[kubectl](https://github.com/kubernetes/kubectl). We can use Colima as our
container runtime, however it's not mandatory to do so. You can subsitute any
other container runtime supported by your machine. It also helps that Colima can
run Kubernetes for us without a lot of setup.

{% include titlebar.html title="zsh" %}

```zsh
brew install docker colima kubectl
```

If you do choose to use Colima, you can edit the configuration and start it in
one command as follows:

{% include titlebar.html title="zsh" %}

```zsh
colima start -k -e # Open settings in $EDITOR before launch
```

## First Steps

Let's start with containerizing a simple application to see what it takes.

{% include titlebar.html title="app.ru" %}

```ruby
# frozen_string_literal: true

require "bundler/inline"

# Set up our dependencies on rack and puma
# Rack is a web server interface
# Puma is a rack compliant web server
gemfile(true) do
  source "https://rubygems.org"

  gem "rack", "2.2.4"
  gem "puma", "5.6.5"
end

# We don't have to define a class in order for this app to
# work with rack. We could have just defined a proc that 
# accepts 1 argument and returns the same array of data.
class Application
  def call(env)
    ['200', {'Content-Type' => 'text/html'}, ["Hello World"]]
  end
end

# Run our application via puma
run Application.new
```

With our app code in hand, we'll also need a `Dockerfile` to build a container
image to run our app.

{% include titlebar.html title="Dockerfile" %}

```Dockerfile
# define our base image to base this one off of
FROM ruby:3.1.2-alpine3.16

# install some dependencies we'll need for our container at runtime
RUN apk --update add --no-cache --virtual run-dependencies \
    build-base && \
    gem install rack:2.2.4 && \
    gem install puma:5.6.5

# copy our app.ru file into the filesystem of our image
COPY app.ru app.ru

# run our application via rackup
CMD rackup app.ru
```

Now we need to turn this code into a container image we can use in later steps.

{% include titlebar.html title="zsh" %}

```zsh
docker build -t rack-app .
```

We need to store our image somewhere that our Kubernetes cluster can pull from.
If you are using a Kubernetes cluster within colima, when we built our docker
image it became available within the cluster as well. If you aren't using
colima, you'll need to push the image to somewhere public like Docker Hub. You
can push to Docker Hub with a command like the following (after authenticating
with them).

{% include titlebar.html title="zsh" %}

```zsh
docker login # authenticate with Docker Hub
docker tag rack-app:latest <docker-hub-username>/rack-app:latest
docker push <docker-hub-username>/rack-app:latest
```

So now we have a very simple rack app and a Dockerfile to build a container
image for it. What now? We'll need some Kubernetes manifest files to describe
the resources we want to create when deploying our app. At the very least we'll
need deployment and service manifests.

{% include titlebar.html title="deploy.yml" %}

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rack-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rack-app
  template:
    metadata:
      labels:
        app: rack-app
    spec:
      containers:
        - name: rack-app
          image: rack-app:latest
          imagePullPolicy: IfNotPresent
```

{% include titlebar.html title="service.yml" %}

```yaml
# service.yml
apiVersion: v1
kind: Service
metadata:
  name: rack-app
spec:
  type: LoadBalancer
  ports:
  - port: 9292
    targetPort: 9292
    protocol: TCP
  selector:
    app: rack-app
```

Let's apply these manifests to our Kubernetes cluster with the following
commands:

{% include titlebar.html title="zsh" %}

```zsh
kubectl apply -f deploy.yml
kubectl apply -f service.yml
```

## It Lives?

Now that our app is deployed to our Kubernetes cluster, let's send a request to
see it working. But first we'll need to get some information to send that
request.

{% include titlebar.html title="zsh" %}

```zsh
kubectl get pods
```

We should get a list of all the running pods (containers) in the default
namespace. Look for one with a name similar to rack-app-78bc8fc8cf-9v7g7. The
last part of the name is random and unique per pod per deployment of our app.
Now that we have the the name of our running pod, we'll run the following to
forward a local port into our cluster directly to our pod.

{% include titlebar.html title="zsh" %}

```zsh
kubectl port-forward rack-app-78bc8fc8cf-9v7g7 9292:9292
curl https://localhost:9292
```

We should get back "Hello World" from our test rack application. Seems like a
success!

## How does Kubernetes know it's alive?

So now we've got to wonder, how does Kubernetes know our pod is running? How
does it know if our pod can accept requests or is even responding correctly to
requests after accepting them?

The first question is easy enough to answer. Kubernetes knows our pod is running
because the single process we started inside the container `rackup app.ru` is
still running. If that process were to die, Kubernetes would notice and recreate
our pod for us. This is because we specified in our `deploy.yml` file that we
wanted 1 pod running at all times.

The second and third question is a bit trickier. If our pod's singular process
were to continue running but wasn't actually accepting requests Kubernetes
wouldn't be able to determine that currently. And if it were accepting requests
but wasn't responding correctly with a `200` and `"Hello World"` it also
couldn't determine that.

So how do we explain to Kubernetes that our pod is alive and well? What we can
do is add a `liveness` probe to our `deploy.yml`. A `liveness` probe tells
Kubernetes that our pod is running correctly and responding as we'd expect. If
the `liveness` probe fails enough over a short period of time, Kubernetes will
terminate the failing pod and replace it with a new one.

{% include titlebar.html title="yaml" %}

```yaml
livenessProde:
  httpGet:
    path: /
    port: 9292
  initialDelaySeconds: 2
  periodSeconds: 5
```

In the case of accepting requests, we can use a `readiness` probe for our pod.
This can let us know if the pod is currently accepting requests. This may seem
similar to our `liveness` probe but there is one key difference between the two.
When a `liveness` probe fails enough, our pod is terminated and replaced. When a
`readiness` probe fails enough, Kubernetes will stop sending traffic to the pod
but it will continue running. It could be our pod is connecting to a database
during normal operation and this connection fails. If that happens, we can no
longer accept connections from the outside. Our app can use the `readiness`
probe to signal to Kubernetes that we currently cannot accept connections.

{% include titlebar.html title="yaml" %}

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 9292
```

Let's update our `deploy.yml` to include both of these probes:

{% include titlebar.html title="deploy.yml" %}

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rack-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rack-app
  template:
    metadata:
      labels:
        app: rack-app
    spec:
      containers:
        - name: rack-app
          image: rack-app:latest
          imagePullPolicy: IfNotPresent
          readinessProbe:
            httpGet:
              path: /
              port: 9292
          livenessProde:
            httpGet:
              path: /
              port: 9292
            initialDelaySeconds: 2
            periodSeconds: 5
```

## Deploys

Now that we've got our app containerized and running in Kubernetes, what about
deploying code updates? We should definitely automate the deployment of our app
so that any code changes can be propogated to our Kubernetes cluster. Looking at
what we have so far, most of our deploy relies on two key pieces. Our image
being stored in a docker registry and our `deploy.yml` Kubernetes manifest.
Let's create a script to build and push our app's container image first.

{% include titlebar.html title="zsh" %}

```zsh
#!/usr/bin/env zsh

# bail out of script if any commands error
set -e 

# set some variables up for reuse
COMMITISH="$(git rev-parse HEAD | CUT -c 1-8)"
PWD="$(pwd)"
PROJECT_NAME="$(basename $PWD)"

docker build -t "$PROJECT_NAME:$BRANCH" .

# on our master branch we tag a deploy version with the COMMITISH
# in the name
if [ "${BRANCH}" = "master" ]; then
  echo "on master branch"
  docker tag "$PROJECT_NAME:$BRANCH" "$PROJECT_NAME:deploy-$COMMITISH"
fi

docker push --all-tags "$PROJECT_NAME"
```

Our build script makes a few assumptions about our project. It assumes we are
using git for version control of the project, our default branch is named
master, the folder containing our project is named after our project and unique,
and we are using a locally accessible registry for Kubernetes.

Next we'll need a script to deploy our app to Kubernetes.

{% include titlebar.html title="zsh" %}

```zsh
#!/usr/bin/env zsh

# bail out of script if any commands error
set -e

# set some variables up for reuse
COMMITISH="$(git rev-parse HEAD | cut -c 1-8)"
export COMMITISH=$COMMITISH

# apply our Kubernetes manifests
kubectl apply -f service.yml
envsubst <deploy.yml | kubectl apply -f -
```

The last part of our deploy script seems a bit strange so let's dive into what's
really happening here. `envsubst` is a command line tool to substitue
environment variables in shell format strings. Using `<`, we are sending the
contents of our `deploy.yml` manifest to the `envsubst` command. This replaces
any mention of `$SOME_VAR` with the current environment variable's value in our
manifest. We can use this to have a static `deploy.yml` but change which tag of
our container we deploy. We'll need to modify our `deploy.yml` to account for
this now.

{% include titlebar.html title="deploy.yml" %}

```yml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rack-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rack-app
  template:
    metadata:
      labels:
        app: rack-app
    spec:
      containers:
        - name: rack-app
          image: rack-app:deploy-$COMMITISH # important bit here
          imagePullPolicy: IfNotPresent
          readinessProbe:
            httpGet:
              path: /
              port: 9292
          livenessProde:
            httpGet:
              path: /
              port: 9292
            initialDelaySeconds: 2
            periodSeconds: 5
```

With both of our scripts at hand, we can now automate our deployment to our
cluster. Since we aren't running any sort of CI/CD platform locally, you can
instead run the scripts locally after making changes and commiting them to git.
But if you were running this in a more 'production' environment, these scripts
could be part of your Continuous Deployment pipeline.

{% include titlebar.html title="zsh" %}

```zsh
bin/docker-build-image
bin/deploy
```

# Final Thoughts

At this point, we've taken our simple rack based app and enabled deploying it to
Kubernetes along with creating a few scripts to help automate the entire
process. Next time we will cover a couple of different applications with
different requirements for operation in a Kubernetes cluster.
