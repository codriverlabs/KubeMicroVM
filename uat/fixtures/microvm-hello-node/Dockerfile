# Use a lightweight Node.js runtime for your application layers
FROM public.ecr.aws/eks-distro-build-tooling/eks-distro-minimal-base-nodejs:16-al23

WORKDIR /app

COPY app.js .

EXPOSE 8080

# Lambda snapshots the running state after CMD starts
CMD ["node", "app.js"]
