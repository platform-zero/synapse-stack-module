package org.webservices.testrunner.suites

import io.ktor.client.statement.*
import io.ktor.http.*
import org.webservices.testrunner.framework.*

suspend fun TestRunner.synapseCommunicationTests() = suite("Synapse Communication Tests") {
test("Synapse homeserver is healthy") {
        val response = client.getRawResponse("${env.endpoints.synapse}/_matrix/client/versions")
        response.status shouldBe HttpStatusCode.OK
        val body = response.bodyAsText()
        body shouldContain "versions"
    }

    test("Synapse federation endpoint responds") {
        val response = client.getRawResponse("${env.endpoints.synapse}/_matrix/federation/v1/version")
        response.status shouldBe HttpStatusCode.OK
    }

    test("Synapse server info is accessible") {
        val response = client.getRawResponse("${env.endpoints.synapse}/_matrix/client/versions")
        response.status shouldBe HttpStatusCode.OK
    }
}
