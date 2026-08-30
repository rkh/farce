<!--
# @title Contributing to Farce
-->

# Contributing to Farce

Contributions to Farce are welcome and appreciated! 💜💜💜

To ensure a smooth contribution process, please follow these guidelines:

1. Do not open issues or pull requests regarding open **security vulnerabilities**. If you discover a security vulnerability, please report it privately to the maintainers by emailing [security@rkh.im](mailto:security@rkh.im) with the subject line "Farce Security Vulnerability Report".
2. **Bug reports** and **pull requests** should be submitted to the [main repository](https://github.com/rkh/farce) on GitHub.
3. Please follow the **[code of conduct](CODE_OF_CONDUCT.md)** in all your interactions with the project and its community.
4. If you use an **AI tool** to assist with your contribution, please follow the guidelines outlined in the [AI contribution policy](#ai-contribution-policy) below.
5. Any code contributions added to Farce directly should be licensed under the **[MIT License](MIT-LICENSE)**. By submitting a pull request, you are agreeing to license your contribution under the MIT License. This does not apply to third-party plugins, repositories, redistributions, or other works that you may link to or reference in your contribution, which may be subject to their own licenses.
6. **Run [the tests](#local-development)** and make sure it's happy before submitting a pull request. If your contribution includes new features, please also add tests and documentation as needed.

Feel free to reach out with any questions and feedback.

Thank you for being part of the Ruby Open Source community and for contributing to Farce! 🙌

## Local Development

You can use [mise](https://mise.jdx.dev) to run tasks against all supported Ruby versions.

 | Task                 | With mise       | Without mise               |
 | -------------------- | --------------- | -------------------------- |
 | install dependencies | `mise install`  | `bundle install`           |
 | compile extensions   | `mise compile`  | `bundle exec rake compile` |
 | run tests            | `mise run test` | `bundle exec rake test`    |
 | builds gems          | `mise build`    | `bundle exec rake gem:all` |

 To install dependencies, compile extensions, run the tests and build the gems, you can run `mise run` (without any arguments) and to do so on file changes, you can use `mise watch`.

 ### Test coverage reports

 If you use mise, this will be handled automatically.

 Otherwise you will need to set the `COVERAGE` environment variable to `true` when running tests. For a full report, you also need to run the tests with different Ruby versions within SimpleCov's merge timeout (defaults to 10 minutes), as they cover different parts of the codebase.

 For instance, using [rvm](https://rvm.io/) could look like this:

 ```bash
 COVERAGE=true rvm 3.4,4.0,jruby do bundle exec rake test
 bundle exec rake coverage:report
 ```

## AI contribution policy

If you wish to use an AI tool for assistance, please adhere to the following guidelines:

* As a contributor, you are always the author and fully accountable for your contributions.
* You must carefully read and review all LLM-generated code or text before asking maintainers to review it. This includes pull request descriptions, where we want to hear your personal voice rather than an unfiltered AI summary.
* You should be transparent and make note if your contribution contains substantial amounts of tool-generated content.
* You should be confident that your contribution is high enough quality to merit a maintainer’s time for review. You should be able to answer questions about your work during review.
* You are responsible for ensuring you have the legal right to make your contribution under our license, and that your contribution does not violate the intellectual property rights of any third party.

Any agents used for contributions may not take action without human review and approval. This includes, but is not limited to, making commits, opening pull requests, or posting in issue trackers.

This policy is based on the [Hanami AI contribution policy](https://discourse.hanamirb.org/t/ai-contribution-policy).
