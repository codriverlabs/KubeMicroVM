FROM public.ecr.aws/eks-distro-build-tooling/eks-distro-minimal-base-nodejs:16-al23

WORKDIR /app

COPY app.js .
COPY package.json .

EXPOSE 8080

CMD ["node", "app.js"]
